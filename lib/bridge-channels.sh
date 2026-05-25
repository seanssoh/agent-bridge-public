#!/usr/bin/env bash
# shellcheck shell=bash

# PR #951 r7 (#946 L1): scripts/smoke/nudge-marker-recovery.sh sources this
# file directly without bridge-lib.sh, so bridge_resolve_script_dir_check
# (defined in bridge-core.sh) would be undefined. Source bridge-core.sh
# idempotently; full-loader path is a no-op via the declare -F gate.
if ! declare -F bridge_resolve_script_dir_check >/dev/null 2>&1; then
  # shellcheck source=lib/bridge-core.sh
  source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/bridge-core.sh"
fi

bridge_channels_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard. Channels helper is reached from
  # many `$(...)` substitutions (precompact route resolution, render,
  # send, webhook status). Without the guard a stale checkout fans out
  # the same [Errno 2] cascade as the daemon-hang on every channel
  # op tick.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
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
  # (group `ab-agent-<X>`, mode 2770, setgid) before writing
  # webhook-port. The daemon (controller) writes this file on behalf of
  # the isolated UID; without the matrix grant the file lands as
  # ec2-user:ab-controller 0644 and the isolated UID cannot re-read it
  # through the leaf. (The per-agent group keeps the integrity boundary
  # — #1165 Gap 6 r2; isolated-hook callers go via the writer's
  # sudo-as-iso path inside bridge_isolation_v2_write_agent_state_marker.)
  if command -v bridge_isolation_v2_ensure_matrix_path >/dev/null 2>&1 \
      && command -v bridge_isolation_v2_active >/dev/null 2>&1 \
      && bridge_isolation_v2_active 2>/dev/null; then
    # r14 codex Probe 4 — was `|| true`. r13 caught the symmetric
    # fallback in the missing-marker retry writer below; this caller
    # was missed. Same anti-pattern: ensure failure means parent dir
    # is not matrix-canonical, so the subsequent mkdir would land
    # mode/group wrong and verify would reject. Hard fail propagates.
    bridge_isolation_v2_ensure_matrix_path "state-agent-dir" "$agent" >/dev/null 2>&1 || return 1
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
              # r15 codex needs-more — was unconditional. The synthetic
              # marker writer now propagates the matrix hard-fail (r12-r14
              # chain), so swallowing here would erase the whole signal.
              # Hard fail: caller (cmd_sync_cycle nudge_scan step) sees
              # rc=1 and emits the new daemon_step_warning audit so
              # operator catches matrix-not-applied via `audit follow`.
              bridge_agent_mark_idle_now "$agent" || return 1
              rm -f "$retries_file"
              bridge_audit_log daemon nudge_marker_synthesized "$agent" \
                --detail consecutive_probe_failures="$retries" \
                --detail max_retries="$max_retries" \
                --detail session="$session" 2>/dev/null || true
              bridge_warn "missing idle-since marker for '$agent' after ${retries} probe failures; synthesized current-timestamp marker so nudge dispatch can resume (issue #629)"
            else
              # v0.9.7 RC2 (refs #781): write retries via the matrix-aware
              # marker writer so the per-agent state leaf inherits the
              # canonical 2770 contract (group `ab-agent-<X>`; #1165 Gap
              # 6 r2 keeps the per-agent integrity boundary and lets the
              # writer sudo-as-iso when invoked from an isolated hook).
              # Falls back to plain mkdir/redirect when the matrix
              # helper isn't loaded.
              # r13 codex Probe F+H catch — drop direct-write fallback.
              # mark_idle_now / mark_manual_stop / webhook-port already
              # propagate hard fail in r12; this writer was missed in
              # the r12 sweep. Same anti-pattern: fallback writes
              # silently defeat the matrix invariant.
              if command -v bridge_isolation_v2_write_agent_state_marker >/dev/null 2>&1 \
                  && command -v bridge_isolation_v2_active >/dev/null 2>&1 \
                  && bridge_isolation_v2_active 2>/dev/null; then
                bridge_isolation_v2_write_agent_state_marker \
                  "$agent" "missing-marker-retries" "$retries" \
                  || return 1
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

# --- Teams plugin runtime provisioning (issue #1074) -----------------------
#
# The bundled Teams channel plugin (plugins/teams/) is a Bun TypeScript MCP
# server. Its .mcp.json invokes `bun ... --no-install server.ts`, which means
# Bun will refuse to auto-install missing deps at runtime; node_modules must
# already exist when the MCP boots. On a fresh install neither the `bun`
# runtime nor the plugin's node_modules are provisioned, so the
# channel-required Teams MCP cannot start (dev-plugin-cache reports
# `node_modules=missing` and the spawn fails with `bun: not found`).
#
# These helpers provision both at `agent-bridge setup teams` time. They are
# idempotent: a second call with bun + node_modules already in place is a
# no-op. `--dry-run` short-circuits both side effects.

# Resolve a usable `bun` executable. Prefers PATH (covers Homebrew, asdf,
# operator-managed installs), falls back to the canonical $HOME/.bun/bin/bun
# location used by the official installer — which is not always on the
# daemon-spawned PATH but is still a valid runtime. Prints the resolved
# absolute path on stdout; returns non-zero with no output when none found.
bridge_resolve_bun_executable() {
  # Codex r1 BLOCKING: the Teams MCP launches bare `bun` (plugins/teams/
  # .mcp.json), so a bun binary that exists at $HOME/.bun/bin/bun is only
  # usable if that path is on the agent's PATH. Accepting a $HOME/.bun/bin
  # fallback here would mark setup successful while the downstream daemon
  # -spawned MCP still hits `bun: not found`. Require PATH-reachability via
  # `command -v` so setup's success claim is truthful end-to-end.
  local candidate=""
  if candidate="$(command -v bun 2>/dev/null)" && [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# Install the Bun runtime via the official installer
# (https://bun.sh/install). Honors --dry-run by reporting the intended action
# without touching the host. Fails closed with a clear operator message when
# `curl` is absent (network-blocked CI / sandbox) — surface the documented
# workaround from issue #1074 rather than hanging in an opaque restart loop.
#
# Returns 0 on success, non-zero with bridge_warn on failure.
bridge_install_bun_runtime() {
  local dry_run="${1:-0}"

  if [[ "$dry_run" == "1" ]]; then
    bridge_info "[setup] [dry-run] would install bun via https://bun.sh/install"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    bridge_warn "bun runtime missing and curl is not available — install bun manually (see https://bun.sh/install) and re-run setup teams"
    return 1
  fi

  bridge_info "[setup] installing bun runtime (https://bun.sh/install)…"
  if ! curl -fsSL https://bun.sh/install | bash >&2; then
    bridge_warn "bun installer failed — install bun manually (see https://bun.sh/install) and re-run setup teams"
    return 1
  fi

  if ! bridge_resolve_bun_executable >/dev/null; then
    bridge_warn "bun installer reported success but \`bun\` is not on PATH — the official installer drops it at \$HOME/.bun/bin/bun and prints a line to add that to your shell rc. Open a new shell (or add \$HOME/.bun/bin to PATH globally for the daemon), then re-run \`agb setup teams <agent>\`."
    return 1
  fi

  return 0
}

# Run `bun install --frozen-lockfile` in the Teams plugin source dir so the
# MCP's deps are resolved at the source. The dev-plugin-cache linker
# (bridge-dev-plugin-cache.py) copies node_modules from source into the
# per-agent cache, so source-side install is the authoritative provisioning
# step. `--frozen-lockfile` keeps the install deterministic against
# `plugins/teams/bun.lock`. Idempotent: skipped when node_modules already
# exists. Honors dry-run.
bridge_install_teams_plugin_node_modules() {
  local dry_run="${1:-0}"
  local bun_bin="${2:-}"
  local plugin_dir=""

  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  plugin_dir="$BRIDGE_SCRIPT_DIR/plugins/teams"

  if [[ ! -d "$plugin_dir" ]]; then
    bridge_warn "Teams plugin source not found at $plugin_dir — skipping bun install"
    return 1
  fi

  # #1165 Gap 3 (r2): the chmod -R go+rX must run on EVERY call when
  # node_modules exists, not only after a fresh `bun install`. The
  # idempotent path (early return when node_modules is already present)
  # is the common case on a re-run of `agb setup teams` after a
  # previous install — if the existing tree was created with the
  # controller's umask (077 → mode 0700), the isolated UID is still
  # locked out and bridge-dev-plugin-cache.py still fails on
  # `Permission denied: '.../plugins/teams/node_modules/.bin/...'`.
  # #1165 r1 only chmod'd after the fresh-install branch (codex catch
  # BLOCKING 2), leaving pre-existing trees unreadable.
  #
  # Apply chmod first (idempotent + cheap when modes are already
  # widened), then decide whether to skip the install. Plugin source
  # files are non-secret git content; the bun lockfile and package.json
  # are already world-readable in the source tree, so this only
  # re-aligns the post-install node_modules tree with the rest of the
  # plugin source. The chmod is best-effort: a failure here does not
  # block setup (the operator may chmod after the fact), but a warning
  # surfaces so the gap is visible.
  if [[ -d "$plugin_dir/node_modules" ]]; then
    if ! chmod -R go+rX "$plugin_dir/node_modules" 2>/dev/null; then
      bridge_warn "chmod -R go+rX failed on $plugin_dir/node_modules — isolated agents may fail to copy via bridge-dev-plugin-cache"
    fi
    bridge_info "[setup] $plugin_dir/node_modules already present — skipping bun install"
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    bridge_info "[setup] [dry-run] would run: bun install --frozen-lockfile in $plugin_dir"
    return 0
  fi

  if [[ -z "$bun_bin" ]]; then
    bun_bin="$(bridge_resolve_bun_executable)" || {
      bridge_warn "bun executable missing after provisioning — cannot bun install in $plugin_dir"
      return 1
    }
  fi

  bridge_info "[setup] running bun install --frozen-lockfile in $plugin_dir"
  if ! ( cd "$plugin_dir" && "$bun_bin" install --frozen-lockfile --no-summary >&2 ); then
    bridge_warn "bun install failed in $plugin_dir — Teams MCP will not start until deps resolve"
    return 1
  fi

  # #1165 Gap 3: bun install runs as the controller, so
  # plugins/teams/node_modules/ inherits the controller umask (often
  # 077 → mode 0700 awfmanager-owned). bridge-dev-plugin-cache.py
  # then runs under the isolated UID's `sudo -u agent-bridge-<a>`
  # context and fails to copy with `Permission denied:
  # '.../plugins/teams/node_modules/.bin/...'`. Widen the tree to
  # `go+rX` (read + traverse for group/other) so any isolated UID can
  # copy it during the per-agent plugin cache materialize step. The
  # chmod is best-effort: a failure here does not block setup (the
  # operator may chmod after the fact), but a warning surfaces so the
  # gap is visible.
  if ! chmod -R go+rX "$plugin_dir/node_modules" 2>/dev/null; then
    bridge_warn "chmod -R go+rX failed on $plugin_dir/node_modules — isolated agents may fail to copy via bridge-dev-plugin-cache"
  fi

  return 0
}

# Make the operator's bun runtime traversable by isolated UIDs.
#
# L1 beta19 (codex r1 design 2026-05-25): the Teams MCP launches bare
# `bun` (plugins/teams/.mcp.json). PR #1090 settled the contract that
# setup requires `command -v bun` to resolve to a PATH-reachable binary
# — but in practice that binary is often a symlink like
# `/usr/local/bin/bun -> $HOME/.bun/bin/bun`. The PATH-visible side is
# fine for the controller, but isolated UIDs need to actually traverse
# `$HOME/.bun/` to reach the real binary. On a Linux box where the
# operator's $HOME is mode 0750 (Debian/Ubuntu default), iso UIDs cannot
# `cd` into `$HOME/.bun` and the MCP fails with EACCES on exec.
#
# Helper behavior:
#   * No-op unless Linux.
#   * No-op when BRIDGE_BUN_CHMOD_OPT_OUT=1 (operator escape hatch).
#   * Resolves `command -v bun`, walks symlinks via `readlink -f` (or a
#     Python fallback for BSD/macOS readlink absence) to the real target.
#   * If the real target sits under $HOME/.bun/: `chmod o+x` on
#     $HOME/.bun and $HOME/.bun/bin — TRAVERSE-ONLY. Never grants `o+r`
#     (no directory listing, no read of $HOME/.bun internals beyond
#     traversal). Other-execute lets iso UIDs reach the resolved file
#     without leaking the rest of the operator's home.
#   * If the real target is anywhere else (homebrew /opt, asdf, fnm
#     shims, system /usr/bin): no-op. Those paths already have global
#     traverse modes; widening them would be a no-op or wrong-scope.
#   * chmod failures are bridge_warn'd, never bridge_die'd — the caller
#     (bridge_provision_teams_plugin_runtime + bridge-upgrade.sh) treats
#     this as best-effort.
#
# Honors --dry-run: emits the chmod commands it WOULD run without
# touching the host. We deliberately do NOT bundle or system-install
# bun: that would require root + system-PATH ownership decisions and
# changes the operator's runtime update model. The chmod-traverse is
# the smallest L1 fix.
bridge_ensure_bun_runtime_traversable_for_isolated() {
  local dry_run="${1:-0}"

  if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    return 0
  fi
  if [[ "${BRIDGE_BUN_CHMOD_OPT_OUT:-0}" == "1" ]]; then
    return 0
  fi

  local bun_path
  if ! bun_path="$(command -v bun 2>/dev/null)" || [[ -z "$bun_path" ]]; then
    # No bun on PATH — bridge_resolve_bun_executable will fail upstream
    # and surface the canonical "missing bun" error. Stay quiet here.
    return 0
  fi

  # Resolve symlinks. Prefer GNU `readlink -f` (Linux default); fall
  # back to Python for portability (Linux without coreutils-style
  # readlink is unusual but cheap to cover).
  local real_target=""
  if real_target="$(readlink -f "$bun_path" 2>/dev/null)" && [[ -n "$real_target" ]]; then
    :
  elif command -v python3 >/dev/null 2>&1; then
    real_target="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$bun_path" 2>/dev/null || true)"
  else
    bridge_warn "bridge_ensure_bun_runtime_traversable_for_isolated: cannot resolve real path of $bun_path (no readlink -f, no python3); skipping traverse chmod"
    return 0
  fi
  if [[ -z "$real_target" ]]; then
    return 0
  fi

  # Only act on $HOME/.bun/ targets. Other PATH-resolved bun installs
  # (homebrew /opt/homebrew, fnm shims under ~/.local/share/fnm, asdf,
  # /usr/bin, etc.) are out of scope — those locations either already
  # have global traverse OR their parent-mode contract is owned by
  # another package manager / system policy we should not mutate.
  local home_bun="${HOME:-}/.bun"
  if [[ -z "${HOME:-}" || -z "$home_bun" ]]; then
    return 0
  fi
  case "$real_target" in
    "$home_bun"/*) ;;
    *) return 0 ;;
  esac

  local bun_bin_dir="$home_bun/bin"

  if [[ "$dry_run" == "1" ]]; then
    bridge_info "[setup] [dry-run] would: chmod o+x $home_bun $bun_bin_dir (isolated-UID traverse for $real_target)"
    return 0
  fi

  # TRAVERSE ONLY — `o+x`, not `o+rx`. Iso UIDs can `cd` into .bun/bin
  # to reach the resolved binary but cannot list .bun/ contents.
  local rc=0
  if [[ -d "$home_bun" ]]; then
    if ! chmod o+x "$home_bun" 2>/dev/null; then
      bridge_warn "chmod o+x $home_bun failed — isolated UIDs may fail to exec bun (Teams MCP startup will hit EACCES)"
      rc=1
    fi
  fi
  if [[ -d "$bun_bin_dir" ]]; then
    if ! chmod o+x "$bun_bin_dir" 2>/dev/null; then
      bridge_warn "chmod o+x $bun_bin_dir failed — isolated UIDs may fail to exec bun (Teams MCP startup will hit EACCES)"
      rc=1
    fi
  fi
  return "$rc"
}

# Channel-setup-time entry point: ensure bun + plugins/teams/node_modules
# are provisioned. Called from bridge-setup.sh `run_teams()` after the
# Python config write succeeds. Failure does not abort setup (operator may
# still want the access.json / runtime config recorded), but emits a clear
# bridge_warn so the operator sees the gap and the workaround.
bridge_provision_teams_plugin_runtime() {
  local dry_run="${1:-0}"
  local bun_bin=""

  if bun_bin="$(bridge_resolve_bun_executable)"; then
    bridge_info "[setup] bun runtime present at $bun_bin"
  else
    bridge_install_bun_runtime "$dry_run" || return 1
    bun_bin="$(bridge_resolve_bun_executable || true)"
  fi

  # L1 beta19 (codex r1 design 2026-05-25): before we provision
  # node_modules (which iso UIDs will read), make sure they can also
  # traverse to the bun binary itself. Best-effort, non-fatal — the
  # helper warns on chmod failure but does not block setup.
  bridge_ensure_bun_runtime_traversable_for_isolated "$dry_run" || true

  bridge_install_teams_plugin_node_modules "$dry_run" "$bun_bin" || return 1

  # L1-J (beta20, 2026-05-25): also provision sibling bundled plugins
  # (ms365, future). The teams-specific helper above covers
  # plugins/teams/ explicitly; this generalized pass picks up any other
  # bundled plugin under $BRIDGE_SCRIPT_DIR/plugins/ that has a
  # package.json. Best-effort + idempotent — re-running on an already-
  # installed plugin is a no-op.
  if bridge_resolve_script_dir_check; then
    bridge_provision_bundled_plugins_node_modules "$dry_run" "$bun_bin" || true
  fi
  return 0
}

# L1-J (beta20, 2026-05-25): provision node_modules for EVERY bundled
# plugin under $BRIDGE_SCRIPT_DIR/plugins/ that has a package.json.
# Generalizes bridge_install_teams_plugin_node_modules so a new bundled
# plugin (e.g. ms365) does not need its own helper.
#
# Skips a plugin when:
#   - it has no package.json (not a node-based MCP)
#   - it already has a node_modules dir newer than package.json + bun.lock
#
# Idempotent: the chmod widen always runs over node_modules so a
# previously-installed-but-tight tree is opened up for iso-UID copy.
bridge_provision_bundled_plugins_node_modules() {
  local dry_run="${1:-0}"
  local bun_bin="${2:-}"

  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  local plugins_root="$BRIDGE_SCRIPT_DIR/plugins"
  if [[ ! -d "$plugins_root" ]]; then
    return 0
  fi

  if [[ -z "$bun_bin" ]]; then
    bun_bin="$(bridge_resolve_bun_executable 2>/dev/null || true)"
  fi
  if [[ -z "$bun_bin" ]]; then
    bridge_warn "[setup] bun executable missing — cannot provision bundled plugin node_modules. Install bun and re-run \`agb setup teams\`."
    return 1
  fi

  local plugin_dir plugin_name pkg_json node_modules bun_lock
  local overall_rc=0
  shopt -s nullglob 2>/dev/null || true
  for plugin_dir in "$plugins_root"/*/; do
    plugin_dir="${plugin_dir%/}"
    [[ -d "$plugin_dir" ]] || continue
    plugin_name="$(basename -- "$plugin_dir")"
    # Already covered by the teams-specific helper.
    [[ "$plugin_name" == "teams" ]] && continue
    case "$plugin_name" in
      .*|marketplaces|cache) continue ;;
    esac
    pkg_json="$plugin_dir/package.json"
    [[ -f "$pkg_json" ]] || continue
    node_modules="$plugin_dir/node_modules"
    bun_lock="$plugin_dir/bun.lock"

    if [[ -d "$node_modules" ]]; then
      local _stale=0
      if [[ "$pkg_json" -nt "$node_modules" ]]; then
        _stale=1
      fi
      if [[ -f "$bun_lock" && "$bun_lock" -nt "$node_modules" ]]; then
        _stale=1
      fi
      if (( _stale == 0 )); then
        chmod -R go+rX "$node_modules" 2>/dev/null \
          || bridge_warn "[setup] chmod go+rX failed on $node_modules (non-fatal)"
        bridge_info "[setup] $plugin_name: node_modules up to date (skipped)"
        continue
      fi
      bridge_info "[setup] $plugin_name: node_modules stale — refreshing"
    fi

    if [[ "$dry_run" == "1" ]]; then
      bridge_info "[setup] [dry-run] would run: bun install in $plugin_dir"
      continue
    fi

    bridge_info "[setup] $plugin_name: running bun install in $plugin_dir"
    local _rc=0
    if [[ -f "$bun_lock" ]]; then
      ( cd "$plugin_dir" && "$bun_bin" install --frozen-lockfile --no-summary >&2 ) || _rc=$?
    else
      ( cd "$plugin_dir" && "$bun_bin" install --no-summary >&2 ) || _rc=$?
    fi
    if (( _rc != 0 )); then
      bridge_warn "[setup] $plugin_name: bun install failed (rc=$_rc) — MCP for this plugin will not start until deps resolve"
      overall_rc=1
      continue
    fi
    if ! chmod -R go+rX "$node_modules" 2>/dev/null; then
      bridge_warn "[setup] $plugin_name: chmod -R go+rX failed on $node_modules — isolated agents may fail to copy via bridge-dev-plugin-cache"
    fi
  done
  return "$overall_rc"
}
