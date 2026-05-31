#!/usr/bin/env bash
# shellcheck shell=bash

# Issue #265 followup to PR #279: wrap `tmux send-keys` with a per-call
# watchdog so a hung tmux child (canonically: send-keys blocked on a closed
# Discord SSL pipe upstream of the pane program) cannot freeze the daemon
# main loop the way the 34-hour silent hang documented in #265 did. PR #279
# wrapped the daemon's python subprocess sites; this closes the actual
# `tmux send-keys` vector the issue body called out.
#
# Default timeout: 10s (override BRIDGE_TMUX_SEND_TIMEOUT_SECONDS). These
# are local IPC to a tmux server on the same host; anything past 10s is a
# genuine hang, not a slow path. The daemon-wide default
# (BRIDGE_DAEMON_SUBPROCESS_TIMEOUT_SECONDS, 30s) is too generous for this
# shape of call.
#
# Only `tmux send-keys` is wrapped — `tmux capture-pane`, `display-message`,
# `set-buffer`, etc. are not on the documented hang path and wrapping them
# would add cost to hot, well-behaved calls.
bridge_tmux_send_keys_with_timeout() {
  local label="$1"
  shift
  local secs="${BRIDGE_TMUX_SEND_TIMEOUT_SECONDS:-10}"
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=10
  # bridge_with_timeout is defined in lib/bridge-state.sh which is sourced
  # AFTER this file in bridge-lib.sh. Bash resolves function names at call
  # time, not source time, so this is safe as long as both modules finish
  # sourcing before any call site runs — which is guaranteed by the
  # bridge-lib.sh load order.
  bridge_with_timeout "$secs" "$label" tmux send-keys "$@"
}

bridge_tmux_send_submit_key() {
  local label="$1"
  local session="$2"
  local engine="${3:-}"
  local requested_mode="${4:-}"
  local pane_target
  local mode
  pane_target="$(bridge_tmux_pane_target "$session")"

  if [[ "$engine" == "claude" ]]; then
    # Claude Code 2.1.158 switched Enter handling under enhanced keyboard
    # protocols: a raw C-m can remain in edit/newline handling, while the
    # physical Enter arrives as CSI-u (ESC [ 13 u). tmux's -H path sends the
    # same bytes without going through key-name translation.
    mode="${requested_mode:-${BRIDGE_TMUX_CLAUDE_SUBMIT_KEY_MODE:-csi-u}}"
    case "$mode" in
      legacy|c-m|C-m|enter|Enter)
        bridge_tmux_send_keys_with_timeout "$label" -t "$pane_target" C-m
        ;;
      csi-u|csiu|CSI-u|CSIU)
        bridge_tmux_send_keys_with_timeout "$label" -t "$pane_target" -H 1b 5b 31 33 75
        ;;
      *)
        bridge_tmux_send_keys_with_timeout "$label" -t "$pane_target" -H 1b 5b 31 33 75
        ;;
    esac
    return
  fi

  bridge_tmux_send_keys_with_timeout "$label" -t "$pane_target" C-m
}

bridge_tmux_session_exists() {
  local session="$1"
  tmux has-session -t "$(bridge_tmux_session_target "$session")" 2>/dev/null
}

bridge_tmux_session_target() {
  local session="$1"
  printf '=%s' "$session"
}

bridge_tmux_pane_target() {
  local session="$1"
  printf '=%s:' "$session"
}

bridge_tmux_session_pane_pid() {
  local session="$1"
  tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{pane_pid}' 2>/dev/null || true
}

bridge_tmux_command_name_is_claude() {
  local command_name="${1:-}"
  local base=""

  [[ -n "$command_name" ]] || return 1
  base="${command_name##*/}"
  case "$base" in
    claude|claude-*|claude.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Issue #835 Wave B: generalized engine-name predicate used by the
# tmux-without-engine detection helper. Mirrors bridge_tmux_command_name_is_claude
# but covers both claude and codex by argument. Kept as a separate function
# (rather than absorbing into _is_claude with an extra arg) so existing
# claude-only call sites keep their narrow contract and a future engine
# kind (e.g., a wrapper "claude-code") is added by extending the case here.
bridge_tmux_command_name_matches_engine() {
  local command_name="${1:-}"
  local engine="${2:-}"
  local base=""

  [[ -n "$command_name" ]] || return 1
  [[ -n "$engine" ]] || return 1
  base="${command_name##*/}"
  case "$engine" in
    claude)
      case "$base" in
        claude|claude-*|claude.*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    codex)
      case "$base" in
        codex|codex-*|codex.*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_tmux_process_tree_has_claude() {
  local root_pid="$1"
  bridge_tmux_process_tree_has_engine "$root_pid" claude
}

# Issue #835 Wave B: engine-agnostic process-tree walker. Walks descendants
# of $root_pid (BFS) and returns 0 if any process's `comm` matches the
# requested engine kind (claude or codex). The pre-existing
# bridge_tmux_process_tree_has_claude is preserved as a thin alias so its
# (claude-only) callers keep their narrow contract; new callers needing
# codex detection or a parameterized engine should use this helper directly.
#
# Implementation mirrors the original claude walker:
#   - BFS bounded by BRIDGE_TMUX_PROCESS_TREE_MAX_PROCS (default 128) to
#     defend against pgrep loops on a process namespace under churn.
#   - `seen` string tracks visited pids without an associative array so the
#     helper still works under Bash 3.x re-exec paths (we re-exec to Bash 4+
#     in entry points, but lib/ helpers are sourced from a variety of
#     contexts including tests that may not re-exec).
#   - pgrep -P expands to ${child_pid}\n list; we filter to numeric only.
#   - Footgun #11 (issue #815): NO heredoc-stdin / here-string. The
#     `done < <(pgrep ...)` process substitution is a /dev/fd pipe, not a
#     here-string, so it's safe.
bridge_tmux_process_tree_has_engine() {
  local root_pid="$1"
  local engine="$2"
  local max_procs="${BRIDGE_TMUX_PROCESS_TREE_MAX_PROCS:-128}"
  local -a queue=()
  local seen=" "
  local pid=""
  local child=""
  local comm=""
  local count=0

  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$engine" ]] || return 1
  [[ "$max_procs" =~ ^[0-9]+$ ]] || max_procs=128
  (( max_procs > 0 )) || max_procs=128

  queue=("$root_pid")
  while ((${#queue[@]} > 0)) && (( count < max_procs )); do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    case "$seen" in
      *" $pid "*) continue ;;
    esac
    seen+="$pid "
    count=$((count + 1))

    comm="$(ps -o comm= -p "$pid" 2>/dev/null | awk '{$1=$1; print}' || true)"
    if bridge_tmux_command_name_matches_engine "$comm" "$engine"; then
      return 0
    fi

    while IFS= read -r child; do
      [[ "$child" =~ ^[0-9]+$ ]] || continue
      case "$seen" in
        *" $child "*) continue ;;
      esac
      queue+=("$child")
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  done

  return 1
}

bridge_tmux_pane_foreground_is_claude() {
  local session="$1"
  local pane_pid=""
  local pane_cmd=""

  pane_pid="$(bridge_tmux_session_pane_pid "$session")"
  if [[ "$pane_pid" =~ ^[0-9]+$ ]] && bridge_tmux_process_tree_has_claude "$pane_pid"; then
    return 0
  fi

  pane_cmd="$(tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{pane_current_command}' 2>/dev/null || true)"
  bridge_tmux_command_name_is_claude "$pane_cmd"
}

# Issue #835 Wave B: tmux-without-engine detection helper.
#
# Returns 0 iff the agent's tmux pane process tree (rooted at the pane_pid
# from `tmux display-message #{pane_pid}`) contains a process whose comm
# matches the agent's declared engine kind (claude or codex). Returns 1 if
# the agent has no live tmux session, the engine kind is not claude/codex
# (the helper is undefined for other shapes), or no engine descendant is
# found within BRIDGE_TMUX_PROCESS_TREE_MAX_PROCS.
#
# Motivation: the operator's 2026-05-14 #835 incident showed that
# `bridge_agent_is_active` only checks `tmux has-session`. When
# bridge-run.sh wedged in the launch-cmd builder (issue #815 follow-up
# wave) the pane existed with only `bridge-run.sh <agent> --continue`
# shells underneath — no `claude` child — yet `agb status` rendered the
# row as `working` because the prompt heuristic in
# bridge_write_roster_status_snapshot couldn't find the engine prompt and
# defaulted to "working". This helper is the missing predicate that
# distinguishes "engine running" from "tmux present but engine never
# spawned (starting/stalled before engine)".
#
# Callers (Wave B integration point): lib/bridge-state.sh::
# bridge_write_roster_status_snapshot, bridge-agent.sh::
# bridge_agent_activity_state, and bridge-daemon.sh::
# bridge_agent_heartbeat_activity_state. All three currently default to
# `working` when prompt is not detected; with this helper they can
# distinguish `starting` (no engine yet) from `working` (engine present
# but mid-turn, no prompt drawn).
bridge_agent_engine_process_alive() {
  local agent="$1"
  local engine="${2:-}"
  local session=""
  local pane_pid=""

  [[ -n "$agent" ]] || return 1
  if [[ -z "$engine" ]]; then
    engine="$(bridge_agent_engine "$agent" 2>/dev/null || true)"
  fi
  # Defined only for prompt-driven engines. Anything else returns 1
  # (caller must treat the helper as "unknown" / fall through to the
  # legacy active-by-tmux check).
  case "$engine" in
    claude|codex) ;;
    *) return 1 ;;
  esac

  session="$(bridge_agent_session "$agent" 2>/dev/null || true)"
  [[ -n "$session" ]] || return 1
  bridge_tmux_session_exists "$session" || return 1

  pane_pid="$(bridge_tmux_session_pane_pid "$session")"
  [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
  bridge_tmux_process_tree_has_engine "$pane_pid" "$engine"
}

bridge_tmux_wait_for_claude_foreground() {
  local session="$1"
  local timeout="${2:-60}"
  local poll="${3:-2}"
  local max_checks="${4:-30}"
  local start_ts=""
  local elapsed=0
  local checks=0

  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=60
  (( timeout > 0 )) || timeout=60
  [[ "$poll" =~ ^[0-9]+([.][0-9]+)?$ ]] || poll=2
  [[ "$max_checks" =~ ^[0-9]+$ ]] || max_checks=30
  (( max_checks > 0 )) || max_checks=30

  start_ts="$(date +%s)"
  while (( checks < max_checks )); do
    if ! bridge_tmux_session_exists "$session"; then
      return 1
    fi
    if bridge_tmux_pane_foreground_is_claude "$session"; then
      return 0
    fi
    checks=$((checks + 1))
    elapsed=$(( $(date +%s) - start_ts ))
    (( elapsed >= timeout )) && break
    sleep "$poll"
  done

  return 1
}

bridge_tmux_kill_session() {
  local session="$1"
  tmux kill-session -t "$(bridge_tmux_session_target "$session")"
}

bridge_tmux_detach_clients() {
  local session="$1"
  tmux detach-client -s "$(bridge_tmux_session_target "$session")"
}

bridge_require_tmux_session() {
  local session="$1"

  if bridge_tmux_session_exists "$session"; then
    return 0
  fi

  echo "현재 활성 세션:"
  tmux list-sessions 2>/dev/null || echo "  (없음)"
  bridge_die "tmux 세션 '$session'이 존재하지 않습니다."
}

bridge_attach_tmux_session() {
  local session="$1"

  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "[info] session '$session' started; attach manually with: tmux attach -t $(bridge_tmux_session_target "$session")"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$(bridge_tmux_session_target "$session")"
  fi

  exec tmux attach -t "$(bridge_tmux_session_target "$session")"
}

bridge_tmux_bootstrap_session_options() {
  local session="$1"
  # tmux's set-option requires the `=<session>:` exact-match form (with
  # trailing colon). The bare `=<session>` form returned by
  # bridge_tmux_session_target fails with "no such session" and the
  # silent `|| true` swallowed it, leaving session-level `mouse` off
  # and wheel events dead (issue #139). Reuse pane target which already
  # appends the colon.
  local target
  target="$(bridge_tmux_pane_target "$session")"
  tmux set-option -t "$target" mouse on >/dev/null 2>&1 || true
  tmux set-option -t "$target" history-limit 10000 >/dev/null 2>&1 || true
}

bridge_tmux_engine_requires_prompt() {
  local engine="$1"

  case "$engine" in
    claude|codex)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_tmux_claude_blocker_state_from_text() {
  local text="$1"

  if [[ "$text" == *"Quick safety check:"* && "$text" == *"Yes, I trust this folder"* ]]; then
    printf '%s' "trust"
    return 0
  fi

  if [[ "$text" == *"Resume from summary (recommended)"* && "$text" == *"Resume full session as-is"* ]]; then
    printf '%s' "summary"
    return 0
  fi

  if [[ "$text" == *"WARNING: Loading development channels"* && "$text" == *"I am using this for local development"* ]]; then
    printf '%s' "devchannels"
    return 0
  fi

  printf '%s' "none"
}

bridge_tmux_claude_blocker_state() {
  local session="$1"
  local recent=""

  recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
  [[ -n "$recent" ]] || {
    printf '%s' "none"
    return 0
  }

  bridge_tmux_claude_blocker_state_from_text "$recent"
}

# Issue #825: pane-content-only check for the dev-channels picker. Returns
# 0 iff the pane has the picker text in view, regardless of foreground
# process basename. This is the primary trigger condition for the
# controller-side auto-accept watcher (bridge-start.sh::
# bridge_start_schedule_dev_channels_accept): on v0.11.0+ live installs the
# foreground basename gate has been observed to false-negative (Claude
# launches under a wrapper whose `comm` does not match the
# claude|claude-*|claude.* regex even after the picker is drawn), wedging
# the watcher indefinitely. The picker text pair detected here
# ("WARNING: Loading development channels" + "I am using this for local
# development") is unique to the Claude dev-channels load path, so its
# presence alone is sufficient evidence the picker has been drawn; no
# additional process-name match is required.
bridge_tmux_pane_has_dev_channels_picker() {
  local session="$1"
  local recent=""

  recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1

  [[ "$(bridge_tmux_claude_blocker_state_from_text "$recent")" == "devchannels" ]]
}

bridge_tmux_claude_prompt_line_ready() {
  local trimmed="$1"
  local remainder=""

  if [[ "$trimmed" == ❯* ]]; then
    remainder="${trimmed#❯}"
  elif [[ "$trimmed" == '>'* ]]; then
    remainder="${trimmed#>}"
  else
    return 1
  fi

  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  if [[ -z "$remainder" ]]; then
    return 0
  fi
  if [[ "$remainder" =~ ^[0-9]+\.[[:space:]] ]]; then
    return 1
  fi
  return 0
}

bridge_tmux_codex_prompt_line_ready() {
  local trimmed="$1"
  [[ "$trimmed" == ›* || "$trimmed" == '>'* ]]
}

bridge_tmux_prompt_line_has_pending_input() {
  local engine="$1"
  local trimmed="$2"
  local remainder=""

  case "$engine" in
    claude)
      # Issue #132: the previous implementation inverted bridge_tmux_claude_prompt_line_ready
      # which only flagged blocker menus (`1. Yes 2. No`), so "> typed text"
      # — an operator mid-compose — was NOT classified as pending. That is
      # precisely why a post-3s-pause daemon injection could interleave with
      # the operator's keystrokes. Here we detect any non-empty remainder
      # after the prompt glyph as pending, except for the numbered-menu
      # blocker pattern (which is handled separately via blocker_state).
      if [[ "$trimmed" == ❯* ]]; then
        remainder="${trimmed#❯}"
      elif [[ "$trimmed" == '>'* ]]; then
        remainder="${trimmed#>}"
      else
        return 1
      fi
      remainder="${remainder#"${remainder%%[![:space:]]*}"}"
      [[ -n "$remainder" ]] || return 1
      [[ "$remainder" =~ ^[0-9]+\.[[:space:]] ]] && return 1
      return 0
      ;;
    codex)
      # Issue #175: prior `return 1` meant `bridge_tmux_session_has_pending_input`
      # was a no-op for codex, so the paste_and_submit retry in issue #175
      # could never observe the "typed but never submitted" race. Mirror the
      # claude remainder-detection: `› <text>` (or the fallback `> <text>`)
      # with non-whitespace remainder counts as pending.
      if [[ "$trimmed" == ›* ]]; then
        remainder="${trimmed#›}"
      elif [[ "$trimmed" == '>'* ]]; then
        remainder="${trimmed#>}"
      else
        return 1
      fi
      remainder="${remainder#"${remainder%%[![:space:]]*}"}"
      [[ -n "$remainder" ]] || return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_tmux_session_has_prompt() {
  local session="$1"
  local engine="$2"
  local recent=""
 
  bridge_tmux_engine_requires_prompt "$engine" || return 0
  recent="$(bridge_capture_recent "$session" 20 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1

  bridge_tmux_session_has_prompt_from_text "$engine" "$recent"
}

bridge_tmux_session_has_prompt_from_text() {
  local engine="$1"
  local recent="$2"
  local line=""
  local trimmed=""

  bridge_tmux_engine_requires_prompt "$engine" || return 0
  [[ -n "$recent" ]] || return 1

  # Issue #815 Wave A: feeding a large tmux capture into the iterator via
  # here-string blocked Bash in `heredoc_write` on the operator's stale
  # runtime. Stage the text through a tempfile and read via `< file` instead.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$recent" > "$_tmp"
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//$'\u00A0'/ }"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$engine" in
      claude)
        if bridge_tmux_claude_prompt_line_ready "$trimmed"; then
          return 0
        fi
        ;;
      codex)
        if bridge_tmux_codex_prompt_line_ready "$trimmed"; then
          return 0
        fi
        ;;
      *)
        if [[ "$trimmed" == '>'* ]]; then
          local remainder="${trimmed#>}"
          remainder="${remainder#"${remainder%%[![:space:]]*}"}"
          [[ -z "$remainder" ]] && return 0
        fi
        ;;
    esac
  done < "$_tmp"

  return 1
}

bridge_tmux_session_has_pending_input_from_text() {
  local engine="$1"
  local recent="$2"
  # Issue #195/#1393 follow-up: optional 3rd arg carries an
  # ANSI-preserving capture of the same pane. Used for prompt ghost-text
  # detection, because Claude/Codex render suggestions as SGR 2 (dim)
  # while real typed input is not dimmed.
  local ansi_recent="${3:-}"
  local line=""
  local trimmed=""
  local last_prompt_line=""

  bridge_tmux_engine_requires_prompt "$engine" || return 1
  [[ -n "$recent" ]] || return 1

  if [[ "$engine" == "claude" ]]; then
    if [[ "$(bridge_tmux_claude_blocker_state_from_text "$recent")" != "none" ]]; then
      return 1
    fi
  fi

  # Claude Code renders the inline auto-complete/guide text in the composer
  # with SGR 2 (dim). Plain tmux capture makes that ghost text look exactly
  # like user input (`❯ suggestion...`), so reject it before the generic
  # non-empty-remainder test below marks the session busy forever.
  if [[ "$engine" == "claude" && -n "$ansi_recent" ]]; then
    if bridge_tmux_claude_last_prompt_is_ghost_text "$ansi_recent"; then
      return 1
    fi
  fi

  # Issue #195 follow-up: if the last `›` line in the codex pane is the
  # placeholder ghost text (SGR 2 / dim), treat the composer as empty so
  # nudges are delivered rather than spooled. Placeholder text is the
  # codex cold-session default; it disappears on any real keystroke, and
  # real typed input is not rendered dim — false-positive risk is low.
  if [[ "$engine" == "codex" && -n "$ansi_recent" ]]; then
    if bridge_tmux_codex_last_prompt_is_placeholder "$ansi_recent"; then
      return 1
    fi
  fi

  # Issue #132: the Claude input box is always the last prompt-glyph line in
  # the TUI. Earlier lines that happen to start with "> " are scrollback
  # (quoted text in an agent response, markdown blockquotes). Remember the
  # LAST line that looks like a prompt and evaluate pending-input on that
  # one only, so quoted content above cannot trigger a permanent defer.
  # Issue #175 (codex review finding): the same applies to codex — a
  # queued `› old text` in scrollback previously caused the old codex
  # branch to return 0 on the first match and mark an idle session as
  # busy. Track last_prompt_line for codex too and evaluate pending-input
  # after the loop on that final line only.
  # Issue #815 Wave A: route the multi-record capture through a tempfile
  # instead of `done <<<` to avoid `heredoc_write` hangs on stale runtimes.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$recent" > "$_tmp"
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//$'\u00A0'/ }"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$engine" in
      claude)
        if [[ "$trimmed" == ❯* || "$trimmed" == '>'* ]]; then
          last_prompt_line="$trimmed"
        fi
        ;;
      codex)
        if [[ "$trimmed" == ›* || "$trimmed" == '>'* ]]; then
          last_prompt_line="$trimmed"
        fi
        ;;
      *)
        if bridge_tmux_prompt_line_has_pending_input "$engine" "$trimmed"; then
          return 0
        fi
        ;;
    esac
  done < "$_tmp"

  if [[ -n "$last_prompt_line" ]]; then
    bridge_tmux_prompt_line_has_pending_input "$engine" "$last_prompt_line"
    return
  fi

  return 1
}

bridge_tmux_capture_has_working_banner() {
  # Issue #1409: pure-text substring predicate. Claude Code (and codex)
  # render a mid-turn status line while a turn is generating / a tool is
  # running — the spinner "Working" / "Imagining…" banner with an "esc to
  # interrupt" hint. This helper is the single owner of that literal
  # banner-string match so the two callers below cannot drift.
  #
  # Scope note: this is a *substring* match over the whole input — it does
  # NOT care where the banner appears. That is correct for the codex
  # submit-landed path (bridge_tmux_codex_submit_landed), which feeds a
  # tight post-C-m capture where the banner appearing at all means the
  # submission was consumed. The claude busy-gate must NOT use this helper
  # directly on a wide 40-line scrollback capture — a stale banner sitting
  # in scrollback above a now-clean composer would false-positive busy and
  # strand legitimate nudges forever (codex review #1409 r1). The claude
  # gate uses bridge_tmux_claude_capture_is_midturn, which adds the
  # region check on top of this primitive.
  #
  # Input: $1 an ANSI-preserving pane capture (or plain text — the match
  # is on the literal banner words, which survive ANSI stripping).
  local ansi_text="$1"
  [[ -n "$ansi_text" ]] || return 1
  if [[ "$ansi_text" == *"Working"* || "$ansi_text" == *"esc to interrupt"* ]]; then
    return 0
  fi
  return 1
}

bridge_tmux_claude_line_is_composer_prompt() {
  # Issue #1409: does this (whitespace-trimmed, ANSI-stripped) line look
  # like Claude Code's interactive composer prompt? The composer renders in
  # two forms across Claude versions / terminal widths:
  #   - bare glyph at the line start:   `❯ ...`  or  `> ...`
  #   - inside a box frame:             `│ > ... │`  (the rounded input box)
  # Either form, appearing BELOW a spinner banner, means the turn has ended
  # and the banner above is stale scrollback. Keep this narrow: a box line
  # only counts when the glyph immediately follows the box border, so prose
  # like "│ note │" or a quoted ">" deep in a response line does not match.
  local trimmed="$1"
  case "$trimmed" in
    ❯*|'>'*) return 0 ;;            # bare composer glyph
    '│ ❯'*|'│ >'*) return 0 ;;      # boxed composer glyph (│ + space + glyph)
    '│❯'*|'│>'*) return 0 ;;        # boxed composer glyph, no inner space
  esac
  return 1
}

bridge_tmux_claude_capture_is_midturn() {
  # Issue #1409 (codex review r1): region-aware mid-turn detector for the
  # Claude busy-gate. Returns 0 (mid-turn → busy) only when the spinner /
  # "esc to interrupt" banner is the LIVE tail status, not stale scrollback.
  #
  # Claude Code's TUI layout: while a turn is generating, the spinner +
  # interrupt-hint banner is rendered at the bottom of the pane and there is
  # no clean composer prompt below it. The moment the turn finishes, the
  # composer prompt box (the `❯ ` / `> ` glyph line) is redrawn as the last
  # interactive line and the banner scrolls up into history. So a banner is
  # only "live" if NO clean composer prompt line appears after the last
  # banner line in the capture. This mirrors the existing scrollback-safe
  # "evaluate the LAST prompt-glyph line only" pattern in
  # bridge_tmux_session_has_pending_input_from_text (issue #132).
  #
  # Input: $1 a plain-text (ANSI-stripped) pane capture. The spinner /
  # interrupt banner and the `❯`/`>` composer glyph all survive ANSI
  # stripping, so the region walk runs on plain text — no SGR parsing.
  local recent="$1"
  [[ -n "$recent" ]] || return 1
  # Cheap reject: no banner anywhere → definitely not mid-turn.
  bridge_tmux_capture_has_working_banner "$recent" || return 1

  local line=""
  local trimmed=""
  # Default to not-mid-turn; flip to 0 on a banner line, back to 1 when a
  # clean composer prompt is seen below it.
  local result=1
  # Issue #815 Wave A: stage the capture through a tempfile rather than a
  # here-string to avoid the Bash 5.3.9 heredoc_write deadlock (footgun #11).
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$recent" > "$_tmp"
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ "$trimmed" == *"Working"* || "$trimmed" == *"esc to interrupt"* ]]; then
      # A banner line — provisionally the live tail until a clean composer
      # prompt is seen below it.
      result=0
    elif bridge_tmux_claude_line_is_composer_prompt "$trimmed"; then
      # A clean Claude composer prompt line appears AFTER a banner → the
      # banner is stale scrollback and the session is back at an idle
      # prompt. Reset so only a later live banner can re-arm busy.
      result=1
    fi
  done < "$_tmp"

  return "$result"
}

bridge_tmux_session_has_pending_input() {
  local session="$1"
  local engine="$2"
  local recent=""
  local ansi_recent=""

  bridge_tmux_engine_requires_prompt "$engine" || return 1
  # Issue #132: use tmux -J so a wrapped prompt line (long mid-compose input
  # that wraps the "> " glyph off to the next visual line on narrow panes) is
  # still detectable as a single logical line. And widen the capture window
  # from 20 to 40 lines so agent output churn cannot push the input box out
  # of view between daemon passes.
  recent="$(bridge_capture_recent "$session" 40 join 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1
  # Issue #195/#1393 follow-up: Claude/Codex ghost text is visually
  # indistinguishable from real typed input once ANSI escapes are stripped.
  # Grab an ANSI-preserving capture too so the detector can reject lines
  # rendered with SGR 2 (dim) as non-pending — otherwise inject_busy flips
  # true and daemon nudges get silently spooled instead of delivered.
  if [[ "$engine" == "claude" || "$engine" == "codex" ]]; then
    ansi_recent="$(bridge_capture_recent_ansi "$session" 40 2>/dev/null || true)"
  fi
  bridge_tmux_session_has_pending_input_from_text "$engine" "$recent" "$ansi_recent"
}

bridge_tmux_session_recent_keypress() {
  local session="$1"
  local threshold="${2:-3}"
  local last_input=""
  local now=""

  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
  (( threshold > 0 )) || return 1
  last_input="$(tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{session_activity}' 2>/dev/null || true)"
  [[ "$last_input" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  (( now - last_input < threshold ))
}

bridge_tmux_session_inject_busy() {
  local session="$1"
  local engine="$2"
  local grace="${3:-3}"

  if bridge_tmux_session_has_pending_input "$session" "$engine"; then
    return 0
  fi

  # Issue #1409: Claude Code will not submit a new message while a turn is
  # already generating / a tool is running — typing the nudge + C-m leaves
  # the text stranded in the composer (logged `submit_lost_post_grace`).
  # The composer-pending and recent-keypress gates above do NOT see that
  # mid-turn state, so detect Claude's spinner banner ("Working" / "esc to
  # interrupt") directly and report busy. The caller then spools the nudge
  # for re-delivery once the session returns to a clean prompt. Codex's
  # own submit path already handles its banner at submit-landed time, so
  # this gate stays claude-specific.
  #
  # The detection is region-aware (codex review #1409 r1): a stale banner
  # in scrollback above a now-clean composer must NOT report busy, or
  # legitimate nudges would be spooled forever. bridge_tmux_claude_capture_
  # is_midturn only treats the banner as live when no clean composer prompt
  # appears below it. Use the same -J joined plain capture window (40 lines)
  # the pending-input gate uses.
  if [[ "$engine" == "claude" ]]; then
    local recent=""
    recent="$(bridge_capture_recent "$session" 40 join 2>/dev/null || true)"
    if bridge_tmux_claude_capture_is_midturn "$recent"; then
      return 0
    fi
  fi

  local attached="0"
  attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf '0')"
  if [[ "$attached" =~ ^[1-9][0-9]*$ ]] && bridge_tmux_session_recent_keypress "$session" "$grace"; then
    return 0
  fi

  return 1
}

bridge_tmux_claude_advance_blocker() {
  local session="$1"
  local allow_devchannels="${2:-0}"
  local expected_state="${3:-}"
  local state=""
  local settle_seconds="${BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_SETTLE_SECONDS:-0.2}"
  local foreground_wait="${BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_WAIT_SECONDS:-60}"
  local foreground_poll="${BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_POLL_SECONDS:-2}"
  local foreground_max="${BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_MAX_CHECKS:-30}"

  state="$(bridge_tmux_claude_blocker_state "$session")"
  # If the caller specified an expected state and the live state has
  # diverged (e.g. devchannels picker cleared and trust prompt appeared
  # in the same poll), refuse to advance — the caller's counter would
  # otherwise mis-attribute the action and widen the budget cap that
  # belongs to the new state.
  if [[ -n "$expected_state" && "$state" != "$expected_state" ]]; then
    return 1
  fi
  case "$state" in
    trust|summary)
      bridge_tmux_send_submit_key "tmux_send_advance_blocker_${state}" "$session" claude
      sleep 0.3
      if [[ "$(bridge_tmux_claude_blocker_state "$session")" == "$state" ]]; then
        bridge_tmux_send_submit_key "tmux_send_advance_blocker_${state}_legacy_retry" "$session" claude legacy
        sleep 0.3
      fi
      return 0
      ;;
    devchannels)
      if [[ "$allow_devchannels" == "1" ]]; then
        if [[ "${BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND:-1}" != "0" ]]; then
          bridge_tmux_wait_for_claude_foreground "$session" "$foreground_wait" "$foreground_poll" "$foreground_max" || return 1
          [[ "$settle_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || settle_seconds="0.2"
          sleep "$settle_seconds"
        fi
        bridge_tmux_send_submit_key tmux_send_advance_blocker_devchannels "$session" claude
        sleep 0.3
        if [[ "$(bridge_tmux_claude_blocker_state "$session")" == "devchannels" ]]; then
          bridge_tmux_send_submit_key tmux_send_advance_blocker_devchannels_legacy_retry "$session" claude legacy
          sleep 0.3
        fi
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_tmux_wait_for_prompt() {
  local session="$1"
  local engine="$2"
  local timeout="${3:-$BRIDGE_TMUX_PROMPT_WAIT_SECONDS}"
  local allow_devchannels="${4:-0}"
  local start_ts
  local elapsed
  local state=""

  # State-specific advance budgets:
  # - trust/summary: existing 4-action limit, preserved to avoid regressing
  #   non-devchannels callers (regular agent restarts, codex sessions, etc.).
  # - devchannels: separate, larger, env-overridable budget so an isolated
  #   agent that needs a 2-step picker confirm + concurrent trust prompt
  #   doesn't exhaust on the 4th attempt before claude finishes drawing.
  #   Default 12 covers picker-confirm-2-step plus a few stale-pane redraws;
  #   operators can tighten it via BRIDGE_TMUX_DEV_CHANNELS_MAX_ADVANCE for
  #   faster fail-loud during diagnosis.
  local trust_summary_actions=0
  local trust_summary_max=4
  local devchannels_actions=0
  local devchannels_max="${BRIDGE_TMUX_DEV_CHANNELS_MAX_ADVANCE:-12}"
  [[ "$devchannels_max" =~ ^[0-9]+$ ]] || devchannels_max=12
  (( devchannels_max > 0 )) || devchannels_max=12

  bridge_tmux_engine_requires_prompt "$engine" || return 0
  if bridge_tmux_session_has_prompt "$session" "$engine"; then
    return 0
  fi
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
  (( timeout > 0 )) || return 1

  start_ts="$(date +%s)"
  while true; do
    if [[ "$engine" == "claude" ]]; then
      state="$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || printf 'none')"
      case "$state" in
        trust|summary)
          if bridge_tmux_claude_advance_blocker "$session" 0 "$state"; then
            trust_summary_actions=$((trust_summary_actions + 1))
            # Re-check prompt before declaring failure; the just-sent C-m
            # may have cleared the blocker.
            if bridge_tmux_session_has_prompt "$session" "$engine"; then
              return 0
            fi
            if (( trust_summary_actions >= trust_summary_max )); then
              bridge_warn "wait_for_prompt: trust/summary advance budget (${trust_summary_max}) exhausted on session=${session}"
              return 1
            fi
          else
            sleep 0.2
          fi
          ;;
        devchannels)
          if [[ "$allow_devchannels" == "1" ]]; then
            if bridge_tmux_claude_advance_blocker "$session" 1 devchannels; then
              devchannels_actions=$((devchannels_actions + 1))
              # Re-check prompt before failing — the picker often clears
              # on the final allowed Enter and we don't want to declare
              # failure when the work is actually done.
              if bridge_tmux_session_has_prompt "$session" "$engine"; then
                return 0
              fi
              if (( devchannels_actions >= devchannels_max )); then
                bridge_warn "wait_for_prompt: devchannels advance budget (${devchannels_max}) exhausted on session=${session}; picker may need manual intervention"
                return 1
              fi
            else
              sleep 0.2
            fi
          else
            # devchannels picker present but auto-accept not allowed —
            # operator must intervene; we cannot bypass it.
            return 1
          fi
          ;;
        *)
          sleep 0.2
          ;;
      esac
    else
      sleep 0.2
    fi
    if bridge_tmux_session_has_prompt "$session" "$engine"; then
      return 0
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      if [[ "$engine" == "claude" && "$state" == "devchannels" && "$allow_devchannels" == "1" \
          && "${BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND:-1}" != "0" \
          && $devchannels_actions -eq 0 ]]; then
        bridge_warn "wait_for_prompt: devchannels picker present but pane foreground never became claude on session=${session}"
      fi
      return 1
    fi
  done
}

bridge_tmux_prepare_claude_session() {
  local session="$1"
  local timeout="${2:-8}"
  local start_ts
  local elapsed
  local advanced=0

  start_ts="$(date +%s)"
  while true; do
    if [[ "$(bridge_tmux_claude_blocker_state "$session")" == "none" ]]; then
      return 0
    fi
    if bridge_tmux_claude_advance_blocker "$session"; then
      advanced=$((advanced + 1))
      if (( advanced >= 4 )); then
        return 1
      fi
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
    sleep 0.2
  done
}

bridge_tmux_paste_signature() {
  # Return a short, distinctive substring from the text we're about to paste,
  # used by bridge_tmux_paste_landed to verify the paste actually reached the
  # composer. First non-empty line truncated to 40 chars — the nudge payload
  # begins with "[Agent Bridge] ..." which is unlikely to collide with codex
  # ghost-text placeholders or scrollback occupying the last visible lines.
  local text="$1"
  local first_line
  first_line="$(printf '%s' "$text" | awk 'NF{gsub(/^[[:space:]]+/, ""); print; exit}' 2>/dev/null || true)"
  printf '%s' "${first_line:0:40}"
}

bridge_tmux_paste_landed() {
  # Landing verification: compare pre- and post-paste captures. The paste
  # landed iff the signature appears in the post capture more often than in
  # the pre capture. Plain substring presence is not enough because prior
  # nudges may have left identical headers in scrollback.
  local pre="$1"
  local post="$2"
  local signature="$3"
  [[ -n "$signature" ]] || return 1
  local pre_hits post_hits
  pre_hits=$(printf '%s' "$pre" | grep -cF -- "$signature" 2>/dev/null || printf '0')
  post_hits=$(printf '%s' "$post" | grep -cF -- "$signature" 2>/dev/null || printf '0')
  [[ "$pre_hits" =~ ^[0-9]+$ ]] || pre_hits=0
  [[ "$post_hits" =~ ^[0-9]+$ ]] || post_hits=0
  (( post_hits > pre_hits ))
}

bridge_tmux_codex_post_paste_is_clean() {
  # Issue #331 Track B: pure-text helper. After paste, the codex composer's
  # last `›` line should now hold the pasted nudge text — NOT the dim
  # placeholder ghost ("› Find and fix a bug in @filename" etc.). When the
  # paste lands visually but composer focus resets the line back to the
  # placeholder, downstream C-m hits an empty input. The classic symptom is
  # `paste_landed` returns true (the signature DOES appear in the post
  # capture, just not on the actual composer line) and yet submit never
  # fires. Reject that state explicitly so the caller can fall back to
  # per-key input.
  #
  # Returns 0 iff the last prompt-glyph line in $1 (ANSI-preserving capture)
  # contains $2 (the paste signature) AND that line is not rendered with the
  # SGR 2 (dim) attribute. Returns 1 otherwise — caller treats as not-clean.
  local ansi_text="$1"
  local signature="$2"
  [[ -n "$ansi_text" ]] || return 1
  [[ -n "$signature" ]] || return 1
  local last_line=""
  local line=""
  # Issue #815 Wave A: stage capture through tempfile (see header note
  # at the top of bridge_tmux_session_has_prompt_from_text).
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$ansi_text" > "$_tmp"
  while IFS= read -r line; do
    if [[ "$line" == *›* ]]; then
      last_line="$line"
    fi
  done < "$_tmp"
  [[ -n "$last_line" ]] || return 1
  case "$last_line" in
    *$'\x1b[2m'*|*$'\x1b[0;2m'*|*$'\x1b[22;2m'*|*$'\x1b[2;'*)
      # Last `›` line is dim — placeholder restored, paste did not stick.
      return 1
      ;;
  esac
  case "$last_line" in
    *"$signature"*)
      return 0
      ;;
  esac
  return 1
}

bridge_tmux_codex_submit_landed() {
  # Issue #331 Track B: pure-text helper. After C-m, decide whether the
  # codex TUI actually consumed the submission or whether the keystroke was
  # absorbed (focus race, placeholder lifecycle reset) and dropped on the
  # floor.
  #
  # Inputs: $1 ANSI-preserving post-C-m capture, $2 the paste signature.
  #
  # Returns 0 (submit landed) iff one of:
  #   (a) the last `›` line in the capture is the dim placeholder AND the
  #       paste signature is no longer present on that line — meaning the
  #       composer cleared and codex is back to its idle ghost-text state
  #       AFTER having something to submit; OR
  #   (b) a "Working" banner / esc-to-interrupt status line is visible —
  #       codex started processing the submission.
  #
  # Returns 1 (submit lost) iff:
  #   - the last `›` line still contains the paste signature (composer kept
  #     the text, never submitted); or
  #   - no `›` line is present at all, no Working banner, capture is empty.
  #
  # Note: the issue #331 failure mode is specifically the case where the
  # last `›` line goes BACK to dim placeholder *without* a Working banner
  # firing. In live captures we cannot reliably tell that apart from "codex
  # submitted then immediately returned to placeholder" except by waiting
  # for the Working banner; treat absence of both signature and Working as
  # ambiguous-fail so the caller falls back. This is the conservative
  # choice — a false-fall-back resends per-key input, which is idempotent
  # at the queue level (the receiving agent claims once even if nudged
  # twice). A false-success wedges the task; we prefer to fall back.
  local ansi_text="$1"
  local signature="$2"
  [[ -n "$ansi_text" ]] || return 1
  [[ -n "$signature" ]] || return 1

  if bridge_tmux_capture_has_working_banner "$ansi_text"; then
    return 0
  fi

  local last_prompt_line=""
  local line=""
  # Issue #815 Wave A: stage capture through tempfile.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$ansi_text" > "$_tmp"
  while IFS= read -r line; do
    if [[ "$line" == *›* ]]; then
      last_prompt_line="$line"
    fi
  done < "$_tmp"

  if [[ -n "$last_prompt_line" && "$last_prompt_line" == *"$signature"* ]]; then
    # Signature still on the composer line — submit did not fire.
    return 1
  fi
  # No Working banner, no signature on the last `›` line. This is the
  # ambiguous case (#331): codex may have submitted and immediately
  # restored the placeholder, or the C-m was absorbed and the placeholder
  # never went anywhere. Treat as fail so the caller retries via the
  # per-key path. The downside is a duplicate nudge if the original
  # actually landed; the receiving agent's claim semantics dedupe at the
  # queue layer.
  return 1
}

bridge_tmux_paste_and_submit() {
  local session="$1"
  local text="$2"
  local engine="${3:-codex}"
  local buffer_name
  local pane_target
  pane_target="$(bridge_tmux_pane_target "$session")"

  buffer_name="bridge-send-$$-$(bridge_nonce)"

  # Issue #195: previous implementation called `paste-buffer -d -p` and
  # trusted that the paste landed in the composer. Codex cold sessions with
  # ghost-text placeholders ("Explain this codebase", "Summarize recent
  # commits") silently drop the first bracketed paste — the C-m that follows
  # lands on a still-empty composer and the daemon logs "nudged" for a
  # delivery that never happened. Verify the paste actually reached the
  # composer via before/after capture diff. On miss, retry without
  # bracketed-paste (-p); if still missing, fall back to per-key input.
  local signature pre_capture post_capture
  signature="$(bridge_tmux_paste_signature "$text")"
  pre_capture="$(bridge_capture_recent "$session" 15 2>/dev/null || true)"

  tmux set-buffer -b "$buffer_name" -- "$text"
  tmux paste-buffer -p -b "$buffer_name" -t "$pane_target"
  sleep 0.1

  post_capture="$(bridge_capture_recent "$session" 15 2>/dev/null || true)"
  if ! bridge_tmux_paste_landed "$pre_capture" "$post_capture" "$signature"; then
    # Bracketed paste may have been absorbed by the placeholder lifecycle
    # instead of the composer. Retry without the -p flag — codex's paste
    # handler treats raw paste as character input, which reliably clears
    # the placeholder on first keystroke.
    tmux paste-buffer -b "$buffer_name" -t "$pane_target"
    sleep 0.15
    post_capture="$(bridge_capture_recent "$session" 15 2>/dev/null || true)"
    if ! bridge_tmux_paste_landed "$pre_capture" "$post_capture" "$signature"; then
      # Both paste attempts lost; fall back to per-key input. type_and_submit
      # bypasses paste-buffer entirely and has its own verify/retry around
      # the submit key (issue #146).
      tmux delete-buffer -b "$buffer_name" 2>/dev/null || true
      bridge_warn "paste did not land in '${session}' composer; falling back to type_and_submit"
      bridge_audit_log daemon tmux_paste_landing_failed "$session" \
        --detail engine="$engine" \
        --detail signature="$signature"
      bridge_tmux_type_and_submit "$session" "$text" "$engine"
      return $?
    fi
  fi
  tmux delete-buffer -b "$buffer_name" 2>/dev/null || true

  # Issue #331 Track B: codex-specific pre-submit composer state check.
  # The plain `paste_landed` test above asks "does the signature appear
  # somewhere in the recent capture" — it does not distinguish between
  # "signature is on the composer line" and "signature is in scrollback
  # while the composer line snapped back to the dim placeholder." The
  # latter is exactly the #331 failure: paste lands visually for one
  # frame, focus lifecycle restores the placeholder, the impending C-m
  # hits an empty input and is dropped. Reject placeholder-restored state
  # before the C-m and fall back to per-key input.
  if [[ "$engine" == "codex" ]]; then
    local pre_submit_ansi
    pre_submit_ansi="$(bridge_capture_recent_ansi "$session" 15 2>/dev/null || true)"
    if [[ -n "$pre_submit_ansi" ]] \
        && ! bridge_tmux_codex_post_paste_is_clean "$pre_submit_ansi" "$signature"; then
      bridge_warn "codex composer placeholder restored after paste in '${session}'; falling back to type_and_submit"
      bridge_audit_log daemon tmux_codex_composer_placeholder_restored "$session" \
        --detail engine="$engine" \
        --detail signature="$signature" \
        --detail stage=pre_submit
      bridge_tmux_type_and_submit "$session" "$text" "$engine"
      return $?
    fi
  fi

  # Issue #175: symmetric verify/retry mirrors bridge_tmux_type_and_submit
  # (issue #146). Fresh codex sessions can miss the first C-m when the TUI
  # hasn't absorbed the paste within the 50ms grace — the submit lands on
  # an empty input line and the paste stays buffered. Warm sessions land
  # instantly; the retry branch only fires under the observed race.
  sleep 0.05
  bridge_tmux_send_submit_key tmux_send_paste_submit "$session" "$engine"
  sleep 0.1
  if bridge_tmux_session_has_pending_input "$session" "$engine"; then
    sleep 0.15
    if [[ "$engine" == "claude" ]]; then
      bridge_tmux_send_submit_key tmux_send_paste_submit_retry "$session" "$engine" legacy
    else
      bridge_tmux_send_submit_key tmux_send_paste_submit_retry "$session" "$engine"
    fi
  fi

  # Issue #331 Track B: codex post-submit state-machine verification. The
  # `pending_input` retry above catches the case where the composer still
  # holds the signature (a clean "C-m absorbed, text intact" race). It
  # does NOT catch the worse #331 case where C-m fired, composer cleared
  # to placeholder, but no Working banner appeared — submit was lost
  # without leaving a trace on the composer line. Capture an ANSI post-
  # state and require either a Working banner or a positive transition
  # away from the signature; otherwise fall back to per-key input.
  if [[ "$engine" == "codex" ]]; then
    sleep 0.1
    local post_submit_ansi
    post_submit_ansi="$(bridge_capture_recent_ansi "$session" 20 2>/dev/null || true)"
    if [[ -n "$post_submit_ansi" ]] \
        && ! bridge_tmux_codex_submit_landed "$post_submit_ansi" "$signature"; then
      bridge_warn "codex submit not observed in '${session}' (no Working banner, signature gone); falling back to type_and_submit"
      bridge_audit_log daemon tmux_codex_submit_lost "$session" \
        --detail engine="$engine" \
        --detail signature="$signature"
      bridge_tmux_type_and_submit "$session" "$text" "$engine"
      return $?
    fi
  fi
}

bridge_tmux_type_and_submit() {
  local session="$1"
  local text="$2"
  # Issue #195 review: accept optional engine arg so the verify/retry gate
  # uses the caller's actual engine. Before this, the submit-retry path was
  # hardcoded to `claude`, which meant codex callers (e.g., the paste-landed
  # fallback from bridge_tmux_paste_and_submit) silently skipped verify —
  # codex's prompt glyph `›` is not matched by the claude detector, so
  # bridge_tmux_session_has_pending_input returned false, no retry fired,
  # and an undelivered fallback nudge would still be reported as success.
  local engine="${3:-claude}"
  local line
  local first_line=1
  local pane_target
  pane_target="$(bridge_tmux_pane_target "$session")"

  # Claude Code 2.1.158 treats Enter inside a multi-line composer as editing
  # rather than submit. Daemon nudges are notifications, not prose drafts, so
  # flatten them before typing to keep C-m on the single-line submit path.
  if [[ "$engine" == "claude" ]]; then
    text="${text//$'\r'/ }"
    text="${text//$'\n'/ }"
  fi

  # Issue #815 Wave A: $text can be a multi-line operator nudge; stage
  # through a tempfile to avoid `heredoc_write` hangs on stale runtimes.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$text" > "$_tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $first_line -eq 0 ]]; then
      bridge_tmux_send_keys_with_timeout tmux_send_type_newline \
        -t "$pane_target" C-j
    fi
    if [[ -n "$line" ]]; then
      bridge_tmux_send_keys_with_timeout tmux_send_type_line \
        -t "$pane_target" -l -- "$line"
    fi
    first_line=0
  done < "$_tmp"

  # Issue #146 + Claude Code 2.1.158 regression: verify after submit and retry
  # while the composer still holds text. For Claude, the first submit uses
  # CSI-u Enter by default for 2.1.158+, while the gated retry falls back to
  # legacy C-m so older Claude builds self-heal without version detection.
  local _submit_grace="${BRIDGE_TMUX_SUBMIT_GRACE_SECONDS:-0.15}"
  local _submit_retries="${BRIDGE_TMUX_SUBMIT_MAX_RETRIES:-5}"
  [[ "$_submit_retries" =~ ^[0-9]+$ ]] || _submit_retries=5
  local _submit_attempt=0
  sleep "$_submit_grace"
  bridge_tmux_send_submit_key tmux_send_type_submit "$session" "$engine"
  while (( _submit_attempt < _submit_retries )); do
    sleep "$_submit_grace"
    bridge_tmux_session_has_pending_input "$session" "$engine" || break
    if [[ "$engine" == "claude" ]]; then
      bridge_tmux_send_submit_key tmux_send_type_submit_retry "$session" "$engine" legacy
    else
      bridge_tmux_send_submit_key tmux_send_type_submit_retry "$session" "$engine"
    fi
    _submit_attempt=$(( _submit_attempt + 1 ))
  done
}

bridge_tmux_send_and_submit() {
  local session="$1"
  local engine="$2"
  local text="$3"
  # Issue #132a: optional 4th arg turns on the pending-attention spool so a
  # busy-gate hit no longer silently drops the event. Unspecified → legacy
  # hard-failure behavior for callers that want immediate operator feedback
  # (e.g., bridge-action.sh: the operator ran `agb send` and should see
  # the failure rather than a background deferral).
  local spool_agent="${4:-}"
  # Issue #132: previous default was 3s. Operators frequently pause >3s while
  # composing (reading, thinking, switching windows), which left a window for
  # daemon injections to land mid-compose. The input-buffer-content check
  # (bridge_tmux_session_has_pending_input) is the primary gate; this
  # timestamp gate is the fallback for cases where the input line itself
  # couldn't be matched. A 10s default is still well under the operator's
  # tolerance for a deferred notification but materially reduces the leak.
  local inject_grace="${BRIDGE_TMUX_INJECT_IDLE_GRACE_SECONDS:-10}"

  if ! bridge_tmux_wait_for_prompt "$session" "$engine"; then
    bridge_warn "session prompt unavailable; skipping send to '$session'"
    if bridge_tmux_spool_enabled "$spool_agent"; then
      bridge_tmux_pending_attention_append "$spool_agent" "$text"
      bridge_tmux_session_ring_bell "$session"
      return 0
    fi
    return 1
  fi
  # Issue #589: send-path branch of the prompt-ready latch. Once
  # bridge_tmux_wait_for_prompt confirms the prompt is live, record it so
  # the daemon's auto-stop idle counter anchors at prompt-ready time
  # rather than session-spawn time. Only emit when we know the agent id
  # (4th arg, omitted by the spool replay path on purpose to avoid
  # re-latching from a deferred entry).
  if [[ -n "$spool_agent" ]]; then
    bridge_agent_note_prompt_ready "$spool_agent" send-path 2>/dev/null || true
  fi
  if bridge_tmux_session_inject_busy "$session" "$engine" "$inject_grace"; then
    # Issue #1312 (Lane ε edge-case 5): busy→idle transition mid-call. The
    # first probe can land while the operator's pending input was already
    # cleared on the next keystroke. Re-check once with a short delay before
    # treating as definitely-busy; this keeps the gate sticky against true
    # contention but avoids unnecessary deferral on a transitioning agent.
    local recheck_delay="${BRIDGE_TMUX_INJECT_BUSY_RECHECK_SECONDS:-0.2}"
    sleep "$recheck_delay" 2>/dev/null || true
    if bridge_tmux_session_inject_busy "$session" "$engine" "$inject_grace"; then
      if bridge_tmux_spool_enabled "$spool_agent"; then
        bridge_tmux_pending_attention_append "$spool_agent" "$text"
        bridge_tmux_session_ring_bell "$session"
        return 0
      fi
      # Issue #1312 (Lane ε): the spool-disabled busy branch used to return
      # 1 with only a warn — the daemon caller (#4451) ignores rc=1 and
      # treats the dispatch as successful, dropping the message permanently.
      # Emit an audit row so the rc=1 has operator-visible evidence even on
      # the explicit-FORCE escape hatch. The audit detail names the reason
      # so KNOWN_ISSUES.md §"tmux_inject_dropped_spool_disabled" can be
      # grep-found.
      bridge_audit_log daemon tmux_inject_dropped_spool_disabled \
        "${spool_agent:-$session}" \
        --detail session="$session" \
        --detail engine="$engine" \
        --detail reason=busy_spool_disabled 2>/dev/null || true
      bridge_warn "session busy and spool disabled; dropping send to '$session' (message lost — see KNOWN_ISSUES.md §tmux_inject_dropped_spool_disabled)"
      return 1
    fi
  fi

  case "$engine" in
    claude)
      bridge_tmux_type_and_submit "$session" "$text" "$engine"
      ;;
    *)
      bridge_tmux_paste_and_submit "$session" "$text" "$engine"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Issue #132a: pending-attention spool.
#
# When a daemon-initiated inject hits the busy gate, rather than silently
# dropping it, the text is escaped and appended to the per-agent spool file
# (bridge_agent_pending_attention_file). A subsequent daemon pass calls
# bridge_tmux_pending_attention_flush, which drains the spool in FIFO order
# and re-injects while the gate is clear. Entries aged past
# BRIDGE_TMUX_INJECT_MAX_DEFER_SECONDS (default 600s) get a `[deferred]`
# marker so the operator can see they are older than a live signal.
#
# The lock is a mkdir spinlock (matches the repo's existing convention in
# lib/bridge-channels.sh::bridge_allocate_dynamic_webhook_port) so the path
# works on Linux and macOS without requiring `flock`.
# ---------------------------------------------------------------------------

bridge_tmux_spool_enabled() {
  # Issue #1312 (v0.15.0-beta5-2 Lane ε): the spool is the only thing that
  # keeps a daemon-initiated inject from being permanently dropped when the
  # agent is busy at inject time. Operator-explicit
  # BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 in an iso-v2 install therefore
  # silently re-enables the data-loss class the spool was built to close.
  # Refuse to honor `=0` when iso v2 is active unless the operator also
  # sets BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=1 (documented escape hatch
  # — last-resort, unsafe). Non-iso installs keep legacy behavior so
  # `=0` remains a no-op-style toggle for them. Per Sean's
  # [[feedback-root-vs-symptom-framing]] directive: prefer refuse over
  # silent failure recovery.
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  local raw="${BRIDGE_TMUX_INJECT_SPOOL_ENABLED:-1}"
  if [[ "$raw" == "1" ]]; then
    return 0
  fi
  # Operator-explicit `=0` (or anything not "1"). Decide whether to honor.
  if [[ "${BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE:-0}" == "1" ]]; then
    if [[ "${_BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED:-0}" != "1" ]]; then
      bridge_warn "BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 honored via FORCE=1 — daemon nudges may be silently dropped when '${agent}' is busy. Unset BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE to restore spool."
      export _BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED=1
    fi
    return 1
  fi
  if command -v bridge_isolation_v2_active >/dev/null 2>&1 \
       && bridge_isolation_v2_active 2>/dev/null; then
    if [[ "${_BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED:-0}" != "1" ]]; then
      bridge_warn "refusing BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 on iso v2 install (spool is the only data-loss guard for busy injects). Set BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=1 to override (unsafe, see KNOWN_ISSUES.md)."
      export _BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED=1
    fi
    return 0
  fi
  return 1
}

bridge_tmux_pending_attention_escape() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\n'/\\n}"
  printf '%s' "$text"
}

bridge_tmux_pending_attention_unescape() {
  local text="$1"
  local out=""
  local i=0
  local ch=""
  local next=""
  local len=${#text}
  while (( i < len )); do
    ch="${text:$i:1}"
    if [[ "$ch" == "\\" && $((i + 1)) -lt $len ]]; then
      next="${text:$((i + 1)):1}"
      case "$next" in
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        \\) out+=$'\\' ;;
        *) out+="\\$next" ;;
      esac
      i=$((i + 2))
    else
      out+="$ch"
      i=$((i + 1))
    fi
  done
  printf '%s' "$out"
}

bridge_tmux_pending_attention_with_lock() {
  local agent="$1"
  local action="$2"
  shift 2
  local lock_dir=""
  local pid_file=""
  local holder_pid=""
  local attempts=0
  local max_attempts="${BRIDGE_TMUX_PENDING_ATTENTION_LOCK_MAX_ATTEMPTS:-200}"
  local rc=0
  [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=200

  lock_dir="$(bridge_agent_pending_attention_lock_dir "$agent")"
  pid_file="$lock_dir/holder.pid"
  mkdir -p "$(dirname "$lock_dir")"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    # Stale-lock recovery: if the holder PID file exists and the holder
    # process is gone, reclaim the lock dir. This avoids the previous
    # implementation's force-rmdir-after-N-attempts which could yank the
    # lock from a still-live holder mid-critical-section and break FIFO
    # ordering of the spool. (Codex review of #132a flagged this.)
    if [[ -f "$pid_file" ]]; then
      holder_pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [[ "$holder_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -f "$pid_file" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null
        continue
      fi
    fi
    attempts=$((attempts + 1))
    if (( attempts >= max_attempts )); then
      # Hard failure rather than lock theft. Caller can retry next pass
      # (the daemon's flush is idempotent — a missed cycle just defers).
      bridge_warn "pending-attention lock contention for '$agent'; giving up after ${max_attempts} attempts"
      return 75
    fi
    sleep 0.05
  done

  printf '%d' $$ 2>/dev/null >"$pid_file"
  "$action" "$agent" "$@"
  rc=$?
  rm -f "$pid_file" 2>/dev/null
  rmdir "$lock_dir" >/dev/null 2>&1 || true
  return $rc
}

_bridge_tmux_pending_attention_append_locked() {
  local agent="$1"
  local text="$2"
  local spool_file=""
  local escaped=""
  local ts=""

  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  mkdir -p "$(dirname "$spool_file")"
  ts="$(date +%s)"
  escaped="$(bridge_tmux_pending_attention_escape "$text")"
  printf '%s\t%s\n' "$ts" "$escaped" >>"$spool_file"
}

bridge_tmux_pending_attention_append() {
  local agent="$1"
  local text="$2"
  [[ -n "$agent" ]] || return 1
  bridge_tmux_pending_attention_with_lock "$agent" \
    _bridge_tmux_pending_attention_append_locked "$text"
}

_bridge_tmux_pending_attention_drain_locked() {
  local agent="$1"
  local spool_file=""

  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  [[ -f "$spool_file" ]] || return 0
  cat "$spool_file"
  : >"$spool_file"
}

bridge_tmux_pending_attention_drain() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  bridge_tmux_pending_attention_with_lock "$agent" \
    _bridge_tmux_pending_attention_drain_locked
}

_bridge_tmux_pending_attention_prepend_locked() {
  local agent="$1"
  local lines="$2"
  local spool_file=""
  local tmp=""

  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  mkdir -p "$(dirname "$spool_file")"
  tmp="$(mktemp "${spool_file}.XXXXXX")"
  printf '%s' "$lines" >"$tmp"
  if [[ -f "$spool_file" ]]; then
    cat "$spool_file" >>"$tmp"
  fi
  mv "$tmp" "$spool_file"
}

bridge_tmux_pending_attention_prepend() {
  local agent="$1"
  local lines="$2"
  [[ -n "$agent" ]] || return 1
  [[ -n "$lines" ]] || return 0
  bridge_tmux_pending_attention_with_lock "$agent" \
    _bridge_tmux_pending_attention_prepend_locked "$lines"
}

bridge_tmux_pending_attention_count() {
  local agent="$1"
  local spool_file=""
  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  [[ -f "$spool_file" ]] || { printf '0'; return 0; }
  awk 'NF>0' "$spool_file" | wc -l | awk '{print $1}'
}

bridge_tmux_session_ring_bell() {
  local session="$1"
  [[ -n "$session" ]] || return 0
  # Best-effort operator cue when an inject is deferred. Rationale for this
  # exact mechanism: `tmux send-keys -l $'\a'` would feed BEL as keyboard
  # input to the pane program, which Claude/Codex TUIs just absorb as
  # Ctrl-G — the operator sees nothing. `display-message` is more reliable:
  # tmux renders it on the status line of any attached client, which is a
  # visible cue on its own. The embedded `\a` is kept on the hope that some
  # clients' terminals still honor it; tmux may sanitize it, which is fine.
  # The durable signal remains the spool file + the session-start context
  # line added in hooks/bridge_hook_common.py::bootstrap_artifact_context.
  tmux display-message -t "$(bridge_tmux_pane_target "$session")" \
    $'\a[Agent Bridge] deferred event queued — input busy' \
    >/dev/null 2>&1 || true
}

bridge_tmux_pending_attention_flush() {
  local session="$1"
  local engine="$2"
  local agent="$3"
  local max_defer="${BRIDGE_TMUX_INJECT_MAX_DEFER_SECONDS:-600}"
  local drained=""
  local now=""
  local unflushed=""
  local line=""
  local ts=""
  local escaped=""
  local decoded=""
  local age=0

  [[ -n "$agent" ]] || return 0
  bridge_tmux_spool_enabled "$agent" || return 0
  drained="$(bridge_tmux_pending_attention_drain "$agent" || true)"
  [[ -n "$drained" ]] || return 0

  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0

  # Issue #815 Wave A: $drained is the entire pending-attention spool
  # for the agent — can be many lines. Stage through a tempfile to
  # avoid `heredoc_write` hangs on stale runtimes. The nested inner
  # `while read` consumes the rest of stdin from the same fd, so it
  # keeps its original heredoc-less shape.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$drained" > "$_tmp"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ts="${line%%$'\t'*}"
    escaped="${line#*$'\t'}"
    decoded="$(bridge_tmux_pending_attention_unescape "$escaped")"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age=$((now - ts))
      if (( age > max_defer )); then
        decoded="[deferred] $decoded"
      fi
    else
      # Unknown age — safer to warn the operator that the replay is stale
      # than to present it as a live signal.
      decoded="[deferred] $decoded"
    fi

    # Pass no agent so send_and_submit returns hard failure on busy instead
    # of re-spooling. Remaining entries go back to the spool via prepend.
    if bridge_tmux_send_and_submit "$session" "$engine" "$decoded"; then
      continue
    fi

    unflushed+="$line"$'\n'
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      unflushed+="$line"$'\n'
    done
    break
  done < "$_tmp"

  if [[ -n "$unflushed" ]]; then
    bridge_tmux_pending_attention_prepend "$agent" "$unflushed"
    return 1
  fi
  return 0
}

bridge_capture_recent() {
  local session="$1"
  local lines="${2:-30}"
  # Pass "join" as $3 to join visually wrapped lines (-J). Needed when the
  # caller regexes single-line artifacts that can wrap across physical pane
  # lines on narrow terminals — e.g., the Claude HUD "Context <bar> NN%"
  # meter (issue #126) and the Claude "> <typed text>" input box at the
  # bottom of the TUI (issue #132). Default behavior (unjoined) preserves
  # every historical caller's output verbatim.
  local mode="${3:-}"
  if [[ "$mode" == "join" ]]; then
    tmux capture-pane -t "$(bridge_tmux_pane_target "$session")" -p -J -S "-$lines"
  else
    tmux capture-pane -t "$(bridge_tmux_pane_target "$session")" -p -S "-$lines"
  fi
}

bridge_capture_recent_ansi() {
  # ANSI-preserving capture. Needed to distinguish Claude/Codex placeholder
  # ghost text — rendered as SGR 2 (dim) — from real typed input that
  # looks textually identical once ANSI escapes are stripped (issue #195
  # follow-up). Kept as a separate helper so existing callers keep their
  # plain-text behavior verbatim.
  local session="$1"
  local lines="${2:-30}"
  tmux capture-pane -t "$(bridge_tmux_pane_target "$session")" -p -e -J -S "-$lines"
}

bridge_tmux_line_has_sgr_dim() {
  local line="$1"
  case "$line" in
    *$'\x1b[2m'*|*$'\x1b[0;2m'*|*$'\x1b[22;2m'*|*$'\x1b[2;'*)
      return 0
      ;;
  esac
  return 1
}

bridge_tmux_claude_last_prompt_is_ghost_text() {
  # Scan an ANSI-preserving capture for the last Claude composer prompt and
  # return 0 (true) if it carries SGR 2 (dim). Claude Code renders inline
  # auto-complete/guide text this way. The suggestion text itself changes
  # constantly, so style is the only stable signal.
  local ansi_text="$1"
  [[ -n "$ansi_text" ]] || return 1
  local last_line=""
  local line=""
  # Issue #815 Wave A: stage capture through tempfile.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$ansi_text" > "$_tmp"
  while IFS= read -r line; do
    if [[ "$line" == *❯* || "$line" == *'>'* ]]; then
      last_line="$line"
    fi
  done < "$_tmp"
  [[ -n "$last_line" ]] || return 1
  bridge_tmux_line_has_sgr_dim "$last_line"
}

bridge_tmux_codex_last_prompt_is_placeholder() {
  # Scan an ANSI-preserving capture for the last line containing the codex
  # prompt glyph (›) and return 0 (true) if that line carries SGR 2 (dim).
  # Codex renders composer placeholder ghost text ("› Summarize recent
  # commits", "› Explain this codebase") with the dim attribute; real
  # typed user input is rendered without it. Before this check,
  # bridge_tmux_session_has_pending_input treated the placeholder as
  # pending input, so the daemon's inject_busy gate spooled nudges into
  # pending-attention.env instead of delivering them (#195 follow-up).
  local ansi_text="$1"
  [[ -n "$ansi_text" ]] || return 1
  local last_line=""
  local line=""
  # Issue #815 Wave A: stage capture through tempfile.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$ansi_text" > "$_tmp"
  while IFS= read -r line; do
    if [[ "$line" == *›* ]]; then
      last_line="$line"
    fi
  done < "$_tmp"
  [[ -n "$last_line" ]] || return 1
  # Match the SGR 2 (dim) forms codex is known to emit. Narrow patterns
  # avoid false positives against 24-bit color sequences like `38;2;r;g;b`
  # which coincidentally contain ";2;" but do not enable dim.
  bridge_tmux_line_has_sgr_dim "$last_line"
}

bridge_sanitize_text() {
  printf '%s' "$1" | tr -d '\000-\011\013-\037'
}

bridge_tmux_session_activity_ts() {
  local session="$1"
  # Use window_activity (updates on pane output) instead of session_activity
  # (only updates on key input). Agents produce output during conversations
  # without key input, so session_activity causes false idle detection.
  tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{window_activity}' 2>/dev/null || true
}

bridge_tmux_session_attached_count() {
  local session="$1"
  tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{session_attached}' 2>/dev/null || true
}

bridge_tmux_session_idle_seconds() {
  local session="$1"
  local activity
  local now

  activity="$(bridge_tmux_session_activity_ts "$session")"
  [[ "$activity" =~ ^[0-9]+$ ]] || {
    printf '0'
    return 0
  }
  now="$(date +%s)"
  (( activity > now )) && activity="$now"
  printf '%s' "$(( now - activity ))"
}
