#!/usr/bin/env bash
# shellcheck shell=bash

bridge_channels_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" "$@"
}

# Resolve the best PreCompact reply target for an opt-in static agent.
# Echoes shell-format assignments (`CHANNEL_ROUTE_PLUGIN=...`,
# `CHANNEL_ROUTE_CHANNEL_ID=...`, `CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID=...`,
# `CHANNEL_ROUTE_LAST_USER_INBOUND_TS=...`, optional `CHANNEL_ROUTE_THREAD_ID=...`)
# on success; exits non-zero with no stdout when there is no eligible route.
# The daemon observer (Track B) consumes this via `eval` and skips silently
# on non-zero exit.
bridge_channel_precompact_target() {
  local agent="$1"
  local channels_csv="$2"
  local recency_seconds="${3:-${BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS:-1800}}"
  local now_ts="${4:-$(date +%s)}"

  bridge_channels_python route-precompact-target \
    --agent "$agent" \
    --channels-csv "$channels_csv" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --recency-seconds "$recency_seconds" \
    --now-ts "$now_ts" \
    --format shell
}

# Send a managed channel message (PreCompact notice or follow-up) — Track B
# of issue #597. The daemon observer calls this after `bridge_channel_precompact_target`
# resolves a route and the Python adapter renders the localized template.
#
# Args (positional):
#   plugin              - "discord" | "telegram" | "teams" | "mattermost"
#   agent               - bridge agent id (used to locate per-agent plugin
#                         credentials under <BRIDGE_HOME>/agents/<agent>/.<plugin>/)
#   channel_id          - platform channel/conversation id from the route
#   reply_to_message_id - platform message id to thread the reply against
#                         (may be empty when the route lacks a per-message
#                         anchor; the Python adapter then sends a plain reply
#                         in the channel and returns no thread id)
#   body                - rendered notice/followup text
#   kind                - "notice" (default) | "followup"; lets adapters
#                         distinguish the two for telemetry only
#   correlation_id      - opaque id propagated into adapter logs (optional)
#
# On success: emits CHANNEL_SEND_* shell assignments on stdout, exit 0.
# On failure: returns non-zero with no partial-success output. The daemon
# catches the non-zero exit and emits a precompact_notice_failed audit row.
#
# BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1 routes the call through the Python
# adapter's --dry-run path so CI/smoke can exercise the shell wrapper
# without performing real network sends.
bridge_channel_send_managed_message() {
  local plugin="${1:-}"
  local agent="${2:-}"
  local channel_id="${3:-}"
  local reply_to_message_id="${4:-}"
  local body="${5:-}"
  local kind="${6:-notice}"
  local correlation_id="${7:-}"

  if [[ -z "$plugin" || -z "$agent" || -z "$channel_id" || -z "$body" ]]; then
    return 2
  fi

  local -a args=(
    send-managed-message
    --plugin "$plugin"
    --agent "$agent"
    --channel-id "$channel_id"
    --body "$body"
    --kind "$kind"
    --bridge-home "$BRIDGE_HOME"
    --bridge-state-dir "$BRIDGE_STATE_DIR"
    --format shell
  )
  if [[ -n "$reply_to_message_id" ]]; then
    args+=(--reply-to-message-id "$reply_to_message_id")
  fi
  if [[ -n "$correlation_id" ]]; then
    args+=(--correlation-id "$correlation_id")
  fi
  if [[ "${BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN:-0}" == "1" ]]; then
    args+=(--dry-run)
  fi

  bridge_channels_python "${args[@]}"
}

bridge_channel_server_script_path() {
  local live_path="$BRIDGE_HOME/bridge-channel-server.py"

  if [[ -f "$live_path" ]]; then
    printf '%s' "$live_path"
    return 0
  fi

  printf '%s/bridge-channel-server.py' "$BRIDGE_SCRIPT_DIR"
}

bridge_channel_server_name() {
  printf '%s' "$BRIDGE_CHANNEL_SERVER_NAME"
}

bridge_agent_mcp_config_path() {
  local agent="$1"
  printf '%s/.mcp.json' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_webhook_port_file() {
  local agent="$1"
  printf '%s/webhook-port' "$(bridge_agent_idle_marker_dir "$agent")"
}

bridge_agent_configured_webhook_port() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_WEBHOOK_PORT[$agent]-}"
}

bridge_webhook_port_is_available() {
  local port="$1"

  bridge_require_python
  python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

bridge_collect_reserved_webhook_ports() {
  local current_agent="${1:-}"
  local agent=""
  local port=""
  local port_file=""

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$agent" == "$current_agent" ]] && continue
    port="$(bridge_agent_configured_webhook_port "$agent")"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
    fi
  done

  shopt -s nullglob
  for port_file in "$BRIDGE_ACTIVE_AGENT_DIR"/*/webhook-port; do
    agent="$(basename "$(dirname "$port_file")")"
    [[ "$agent" == "$current_agent" ]] && continue
    port="$(<"$port_file")"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
    fi
  done
  shopt -u nullglob
}

bridge_allocate_dynamic_webhook_port() {
  local agent="$1"
  local lock_dir="$BRIDGE_STATE_DIR/webhook-port.lock"
  local start="$BRIDGE_WEBHOOK_PORT_RANGE_START"
  local end="$BRIDGE_WEBHOOK_PORT_RANGE_END"
  local port_file
  local port
  local -A reserved=()
  local reserved_port

  [[ "$start" =~ ^[0-9]+$ ]] || start=9101
  [[ "$end" =~ ^[0-9]+$ ]] || end=9199
  (( start <= end )) || bridge_die "invalid webhook port range: ${start}-${end}"

  mkdir -p "$BRIDGE_STATE_DIR"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.05
  done
  trap 'rmdir "$lock_dir" >/dev/null 2>&1 || true' RETURN

  port_file="$(bridge_agent_webhook_port_file "$agent")"
  # v0.9.7 (refs #781 RC2): ensure the per-agent state leaf is canonical
  # (group ab-agent-<X>, 2770, setgid) before writing webhook-port. The
  # daemon writes this file on behalf of the isolated UID; without the
  # matrix grant the file lands as ec2-user:ab-controller 0644 and the
  # isolated UID may need to re-read it through the leaf.
  if command -v bridge_isolation_v2_ensure_matrix_path >/dev/null 2>&1 \
      && command -v bridge_isolation_v2_active >/dev/null 2>&1 \
      && bridge_isolation_v2_active 2>/dev/null; then
    bridge_isolation_v2_ensure_matrix_path "state-agent-dir" "$agent" >/dev/null 2>&1 || true
  fi
  mkdir -p "$(dirname "$port_file")"
  if [[ -f "$port_file" ]]; then
    port="$(<"$port_file")"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s' "$port"
      return 0
    fi
  fi

  while IFS= read -r reserved_port; do
    [[ "$reserved_port" =~ ^[0-9]+$ ]] || continue
    reserved["$reserved_port"]=1
  done < <(bridge_collect_reserved_webhook_ports "$agent")

  for ((port=start; port<=end; port++)); do
    [[ -z "${reserved[$port]-}" ]] || continue
    if ! bridge_webhook_port_is_available "$port"; then
      continue
    fi
    # r12 codex Probe 9 — drop direct-write fallback. Matrix writer
    # failure is signal that the per-agent state-dir is not canonical,
    # so a fallback write would land mode/group wrong and verify would
    # reject. Hard fail propagates.
    if command -v bridge_isolation_v2_write_agent_state_marker >/dev/null 2>&1 \
        && command -v bridge_isolation_v2_active >/dev/null 2>&1 \
        && bridge_isolation_v2_active 2>/dev/null; then
      bridge_isolation_v2_write_agent_state_marker "$agent" "webhook-port" "$port" || return 1
    else
      printf '%s\n' "$port" >"$port_file"
    fi
    printf '%s' "$port"
    return 0
  done

  return 1
}

bridge_agent_webhook_port() {
  local agent="$1"
  local configured=""
  local port_file=""
  local port=""

  configured="$(bridge_agent_configured_webhook_port "$agent")"
  if [[ "$configured" =~ ^[0-9]+$ ]]; then
    printf '%s' "$configured"
    return 0
  fi

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  [[ "$(bridge_agent_source "$agent")" == "dynamic" ]] || return 1

  port_file="$(bridge_agent_webhook_port_file "$agent")"
  if [[ -f "$port_file" ]]; then
    port="$(<"$port_file")"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s' "$port"
      return 0
    fi
  fi

  bridge_allocate_dynamic_webhook_port "$agent"
}

bridge_agent_has_webhook_port() {
  local agent="$1"
  [[ -n "$(bridge_agent_webhook_port "$agent" 2>/dev/null || true)" ]]
}

bridge_ensure_claude_webhook_channel() {
  local agent="$1"
  local workdir="${2:-$(bridge_agent_workdir "$agent")}"
  local port=""

  port="$(bridge_agent_webhook_port "$agent" 2>/dev/null || true)"
  [[ -n "$port" ]] || return 1

  bridge_channels_python ensure-webhook-server \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --python-bin "$(command -v python3)" \
    --server-script "$(bridge_channel_server_script_path)" \
    --server-name "$(bridge_channel_server_name)" \
    --port "$port" \
    --agent "$agent"
}

bridge_claude_webhook_channel_status() {
  local agent="$1"
  local workdir="${2:-$(bridge_agent_workdir "$agent")}"
  local port=""

  port="$(bridge_agent_webhook_port "$agent" 2>/dev/null || true)"
  [[ -n "$port" ]] || return 1

  bridge_channels_python status-webhook-server \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --python-bin "$(command -v python3)" \
    --server-script "$(bridge_channel_server_script_path)" \
    --server-name "$(bridge_channel_server_name)" \
    --port "$port" \
    --agent "$agent"
}

bridge_disable_claude_webhook_channel() {
  local agent="$1"
  local workdir="${2:-$(bridge_agent_workdir "$agent")}"
  local port=""

  port="$(bridge_agent_webhook_port "$agent" 2>/dev/null || true)"
  [[ -n "$port" ]] || port=0

  bridge_channels_python remove-webhook-server \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --python-bin "$(command -v python3)" \
    --server-script "$(bridge_channel_server_script_path)" \
    --server-name "$(bridge_channel_server_name)" \
    --port "$port" \
    --agent "$agent"
}

bridge_claude_launch_with_webhook() {
  local agent="$1"
  local base_cmd="$2"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' "$base_cmd"
    return 0
  }
  printf '%s' "$base_cmd"
}

bridge_post_channel_webhook() {
  local agent="$1"
  local message="$2"
  local port=""

  port="$(bridge_agent_webhook_port "$agent" 2>/dev/null || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  bridge_require_python
  python3 - "$port" "$message" <<'PY'
import json
import sys
import urllib.error
import urllib.request

port = int(sys.argv[1])
message = sys.argv[2]
request = urllib.request.Request(
    f"http://127.0.0.1:{port}/",
    data=message.encode("utf-8"),
    headers={"Content-Type": "text/plain; charset=utf-8"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=3) as response:
        if response.status < 200 or response.status >= 300:
            raise SystemExit(1)
except (urllib.error.URLError, TimeoutError):
    raise SystemExit(1)
PY
}

bridge_write_idle_ready_agents() {
  local file="$1"
  local agent=""
  local session=""
  local engine=""
  local retries_file=""
  local retries=0
  local max_retries="${BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS:-3}"
  # Issue #633 codex r1 finding: an invalid override (non-numeric, empty,
  # or <1) used to trip `set -u` at the arithmetic compare below
  # (`abc: unbound variable`), aborting the entire daemon nudge_scan
  # cycle. Fall back silently to the documented default 3 — the operator
  # set the env var, so a one-time stderr warn surfaces the typo without
  # spamming the daemon log on every cycle.
  if ! [[ "$max_retries" =~ ^[0-9]+$ ]] || (( 10#$max_retries < 1 )); then
    if [[ -z "${BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS_WARNED:-}" ]]; then
      bridge_warn "BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS='${BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS:-}' is not a positive integer; falling back to default 3 (issue #629/#633)"
      export BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS_WARNED=1
    fi
    max_retries=3
  fi

  : >"$file"
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    bridge_agent_is_active "$agent" || continue
    engine="$(bridge_agent_engine "$agent")"
    session="$(bridge_agent_session "$agent")"

    case "$engine" in
      claude)
        if ! bridge_agent_idle_marker_exists "$agent"; then
          # A missing marker most often means a turn aborted before the
          # Stop hook fired (Anthropic 429 quota cap, network drop, etc.).
          # Reuse the visual-prompt probe that bridge_dispatch_notification
          # already calls at dispatch time so the agent rejoins the ready
          # list as soon as its tmux pane is back at a Claude prompt.
          retries_file="$(bridge_agent_missing_marker_retries_file "$agent")"
          if bridge_claude_session_try_mark_prompt_ready "$agent" "$session"; then
            # Probe succeeded — marker now written, reset the retry counter.
            rm -f "$retries_file"
          else
            # Issue #629: a single probe failure used to exclude the agent
            # from the nudge list; if the probe kept failing across cycles
            # (dialog overlay, copy-mode, post-429 stall), the agent went
            # silent indefinitely (SYRS librarian observed 5h+ silent on
            # 5/5). Persist a per-agent retry counter and, after
            # max_retries consecutive failures, synthesize an idle-since
            # marker so the dispatcher's normal nudge logic can take over.
            # The synthetic marker is conservative: at worst one nudge
            # lands on a non-ready pane (recoverable); indefinite silence
            # is worse.
            retries=0
            if [[ -f "$retries_file" ]]; then
              retries="$(cat "$retries_file" 2>/dev/null || printf '0')"
              [[ "$retries" =~ ^[0-9]+$ ]] || retries=0
            fi
            retries=$((retries + 1))
            if (( retries >= 10#$max_retries )); then
              bridge_agent_mark_idle_now "$agent"
              rm -f "$retries_file"
              bridge_audit_log daemon nudge_marker_synthesized "$agent" \
                --detail consecutive_probe_failures="$retries" \
                --detail max_retries="$max_retries" \
                --detail session="$session" 2>/dev/null || true
              bridge_warn "missing idle-since marker for '$agent' after ${retries} probe failures; synthesized current-timestamp marker so nudge dispatch can resume (issue #629)"
            else
              # v0.9.7 RC2 (refs #781): write retries via the matrix-aware
              # marker writer so the per-agent state leaf inherits the
              # canonical ab-agent-<X> 2770 contract. Falls back to plain
              # mkdir/redirect when the matrix helper isn't loaded.
              if command -v bridge_isolation_v2_write_agent_state_marker >/dev/null 2>&1 \
                  && command -v bridge_isolation_v2_active >/dev/null 2>&1 \
                  && bridge_isolation_v2_active 2>/dev/null; then
                bridge_isolation_v2_write_agent_state_marker \
                  "$agent" "missing-marker-retries" "$retries" \
                  || { mkdir -p "$(bridge_agent_idle_marker_dir "$agent")"; printf '%s\n' "$retries" >"$retries_file"; }
              else
                mkdir -p "$(bridge_agent_idle_marker_dir "$agent")"
                printf '%s\n' "$retries" >"$retries_file"
              fi
              continue
            fi
          fi
        fi
        ;;
      codex)
        bridge_tmux_session_has_prompt "$session" "$engine" || continue
        ;;
      *)
        continue
        ;;
    esac

    printf '%s\n' "$agent" >>"$file"
  done
}
