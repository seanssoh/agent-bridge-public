#!/usr/bin/env bash
# shellcheck shell=bash

bridge_notify_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-notify.py" "$@"
}

bridge_notify_send() {
  local agent="$1"
  local title="$2"
  local message="$3"
  local task_id="${4:-}"
  local priority="${5:-normal}"
  local dry_run="${6:-0}"
  local kind=""
  local target=""
  local account=""
  local args=()

  kind="$(bridge_agent_notify_kind "$agent")"
  target="$(bridge_agent_notify_target "$agent")"
  account="$(bridge_agent_notify_account "$agent")"

  [[ -n "$kind" ]] || bridge_die "notify kind이 설정되지 않았습니다: $agent"
  [[ -n "$target" ]] || bridge_die "notify target이 설정되지 않았습니다: $agent"

  args=(
    send
    --agent "$agent"
    --kind "$kind"
    --target "$target"
    --runtime-config "$(bridge_compat_config_file)"
  )
  if [[ -n "$account" ]]; then
    args+=(--account "$account")
  fi
  if [[ -n "$title" ]]; then
    args+=(--title "$title")
  fi
  if [[ -n "$message" ]]; then
    args+=(--message "$message")
  fi
  if [[ -n "$task_id" ]]; then
    args+=(--task-id "$task_id")
  fi
  if [[ -n "$priority" ]]; then
    args+=(--priority "$priority")
  fi
  if [[ "$dry_run" == "1" ]]; then
    args+=(--dry-run)
  fi

  bridge_audit_log notify external_channel_send "$agent" \
    --detail kind="$kind" \
    --detail transport_target="$target" \
    --detail account="$account" \
    --detail priority="$priority" \
    --detail dry_run="$dry_run" \
    --detail title="$title"

  bridge_notify_python "${args[@]}"
}

bridge_warn_missing_wake_channel() {
  local agent="$1"

  bridge_warn "Claude agent '${agent}' has no local session configured. Queue tasks remain durable, but idle wake cannot run without a live tmux session."
}

bridge_claude_session_can_wake() {
  local agent="$1"
  [[ -f "$(bridge_agent_idle_since_file "$agent")" ]]
}

bridge_claude_session_try_mark_prompt_ready() {
  local agent="$1"
  local session="$2"

  [[ -n "$session" ]] || return 1
  bridge_tmux_session_exists "$session" || return 1
  bridge_tmux_session_has_prompt "$session" claude || return 1
  # r13 codex Probe E catch — was unconditional `return 0` after the
  # mark_idle call, swallowing the new hard-fail propagation from r12.
  # Now propagate so callers (channels prompt-detector, notify path)
  # see the failure when the matrix writer rejects.
  bridge_agent_mark_idle_now "$agent" || return 1
  return 0
}

bridge_notification_text() {
  local title="$1"
  local message="$2"
  local task_id="${3:-}"
  local priority="${4:-normal}"
  local header="[Agent Bridge]"

  if [[ -n "$priority" && "$priority" != "normal" ]]; then
    header+=" $priority"
  fi
  if [[ -n "$task_id" ]]; then
    header+=" task #${task_id}"
  fi
  if [[ -n "$title" ]]; then
    header+=": ${title}"
  fi

  if [[ -n "$message" ]]; then
    printf '%s\n%s' "$header" "$message"
    return 0
  fi

  printf '%s' "$header"
}

# ---------------------------------------------------------------------------
# Issue #132b: metadata-only injection payload helper.
#
# Legacy injections embed an execution verb
# ("Run exactly: ~/.agent-bridge/agb inbox $agent"). The redesigned payload
# is metadata-only so the main agent can parse the event, read the task
# spec via `agb show <id>`, compose its own subagent prompt with acceptance
# criteria, dispatch via Task, verify, and report one line — keeping the
# main context clean. See upstream #132 Axis B and the external-push-handling
# shared skill (#132c) for the handling routine.
#
# This PR adds the helper + opt-in flag only. Call sites emit legacy output
# unless BRIDGE_INJECT_METADATA_ONLY=1. Flip the flag only after the
# external-push-handling skill is shipped — otherwise agents would receive
# metadata without a handler.
#
# Payload shape:
#   [Agent Bridge] event=inbox count=3 top=X12 title='fix docs typo' from=patch
#
# Value encoding: bare token for letters/digits/.-_@:/, otherwise
# single-quoted with '\'' escape for embedded single quotes.
# ---------------------------------------------------------------------------

bridge_inject_metadata_only_enabled() {
  [[ "${BRIDGE_INJECT_METADATA_ONLY:-0}" == "1" ]]
}

bridge_inject_meta_escape_value() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf "''"
    return 0
  fi
  # Metadata injections are a single logical line — so any embedded CR/LF in
  # a value (e.g., a task title that survived `.strip()` but contained a
  # newline) must be folded to an ASCII sentinel to avoid producing a
  # payload the parser would split into two events. The "\\n" sentinel is
  # chosen so a consumer can reliably reverse it when displaying the title.
  v="${v//$'\r'/}"
  v="${v//$'\n'/\\n}"
  if [[ "$v" =~ ^[A-Za-z0-9._/@:-]+$ ]]; then
    printf '%s' "$v"
    return 0
  fi
  local escaped="${v//\'/\'\\\'\'}"
  printf "'%s'" "$escaped"
}

bridge_format_injection_meta() {
  # Usage: bridge_format_injection_meta <kind> [<key>=<val> ...]
  # Emits: [Agent Bridge] event=<kind> <key>=<escaped-val> ...
  local kind="$1"
  shift
  local out="[Agent Bridge] event="
  out+="$(bridge_inject_meta_escape_value "$kind")"
  local pair=""
  local key=""
  local val=""
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    [[ -n "$key" ]] || continue
    out+=" ${key}=$(bridge_inject_meta_escape_value "$val")"
  done
  printf '%s' "$out"
}

bridge_queue_attention_title() {
  local queued="$1"
  printf '%s' "ACTION REQUIRED — queued tasks (${queued})"
}

bridge_queue_attention_message() {
  local agent="$1"
  local queued="$2"
  local task_id="${3:-}"
  local task_priority="${4:-normal}"
  local task_title="${5:-}"

  if bridge_inject_metadata_only_enabled; then
    # Issue #132b: no execution verb; main agent parses metadata and drives
    # the flow via the external-push-handling shared skill (#132c). Emit a
    # single logical line — no trailing newline — so the injected payload is
    # one event, not two (the blank follow-up would otherwise be read as a
    # separate message by the injection path).
    bridge_format_injection_meta inbox \
      agent="$agent" \
      count="$queued" \
      top="${task_id:-}" \
      priority="$task_priority" \
      title="${task_title:-}"
    return 0
  fi

  printf '[Agent Bridge] %s pending task(s) for %s.\n' "$queued" "$agent"
  if [[ -n "$task_id" && -n "$task_title" ]]; then
    printf 'Highest priority: Task #%s [%s] %s\n' "$task_id" "$task_priority" "$task_title"
  fi
  printf 'ACTION REQUIRED: Use your Bash tool now. Do not acknowledge or reply conversationally first.\n'
  printf 'Run exactly: ~/.agent-bridge/agb inbox %s\n' "$agent"
  printf 'If tasks are listed, show and claim the first one immediately.\n'
  printf 'Queue DB is source of truth.\n'
}

bridge_dispatch_notification() {
  local agent="$1"
  local title="$2"
  local message="$3"
  local task_id="${4:-}"
  local priority="${5:-normal}"
  local engine=""
  local session=""
  local text=""

  engine="$(bridge_agent_engine "$agent")"

  # Issue #132b followup: compute the payload BEFORE the engine-specific
  # dispatch so the passthrough gate (metadata-only mode + payload already
  # carries the [Agent Bridge] event= header) applies uniformly to claude
  # AND non-claude engines. The previous implementation gated only the
  # claude branch, so a Codex agent's wake would get the legacy header
  # wrapping reapplied even when $message was already a complete metadata
  # payload — producing two-event injection text. Comment context: the
  # gate matters because bridge_dispatch_notification is the shared helper
  # called from bridge-task/send/intake/review/bundle with plain messages
  # that still need the legacy header; only skip wrapping when the message
  # has the metadata header verbatim.
  if bridge_inject_metadata_only_enabled \
     && [[ "$message" == "[Agent Bridge] event="* ]]; then
    text="$message"
  else
    text="$(bridge_notification_text "$title" "$message" "$task_id" "$priority")"
  fi

  case "$engine" in
    claude)
      session="$(bridge_agent_session "$agent")"
      if [[ -z "$session" ]] || ! bridge_tmux_session_exists "$session"; then
        return 2
      fi
      if ! bridge_agent_has_wake_channel "$agent"; then
        bridge_warn_missing_wake_channel "$agent"
        return 2
      fi
      if ! bridge_claude_session_can_wake "$agent" "$session"; then
        if ! bridge_claude_session_try_mark_prompt_ready "$agent" "$session"; then
          # Issue #589 Part B: the session exists but the wake-channel marker
          # has not been written yet (Claude is still booting). Today this
          # branch returns 2, the daemon treats it as a soft skip, and the
          # nudge is dropped — the original task stays queued and 547+ of
          # these warnings can accumulate over a 16-min boot. Spool the
          # payload so the daemon's flush loop re-delivers it once the
          # session reaches the prompt. Returning 0 here marks the dispatch
          # as successful for `nudge_agent_session`'s last_nudge_key dup-
          # suppression, so the same queued task ids do not produce repeat
          # spool entries on every 5s tick.
          if bridge_tmux_spool_enabled "$agent"; then
            bridge_tmux_pending_attention_append "$agent" "$text"
            return 0
          fi
          return 2
        fi
      fi

      # Issue #132a: pass $agent so a busy gate at inject time routes through
      # the pending-attention spool instead of silently dropping the wake.
      if bridge_tmux_send_and_submit "$session" "$engine" "$text" "$agent"; then
        return 0
      fi
      bridge_warn "Claude idle wake delivery failed for '${agent}'"
      return 1
      ;;
    *)
      session="$(bridge_agent_session "$agent")"
      if [[ -z "$session" ]]; then
        bridge_warn "session unavailable; skipping direct send to '${agent}'"
        return 1
      fi
      if ! bridge_tmux_session_exists "$session"; then
        bridge_warn "session unavailable; skipping direct send to '${agent}'"
        return 1
      fi
      bridge_tmux_send_and_submit "$session" "$engine" "$text" "$agent"
      ;;
  esac
}
