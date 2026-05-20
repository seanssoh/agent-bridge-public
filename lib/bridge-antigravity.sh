#!/usr/bin/env bash
# lib/bridge-antigravity.sh — Antigravity (`agy`) launch contract.
#
# Track C1 of the Antigravity engine wave. This module owns everything the
# bridge needs to make a managed `agy` agent actually spawnable WITH the
# bridge context the Claude/Codex agents get via SessionStart hooks:
#
#   - bridge_antigravity_settings_preseed — atomic preseed of the agy
#     settings.json (trust workspace, allow the bridge CLIs, pin
#     altScreenMode=always so tmux capture-pane idle detection is
#     deterministic — agy v1.0.0 rejects the "inline" value).
#   - bridge_antigravity_dynamic_launch_cmd — builds the launch argv with
#     the mandatory `-i <bootstrap-prompt>` for fresh sessions and the
#     `--conversation <id>` resume form.
#   - conversation-state path helpers under ~/.gemini/antigravity-cli/
#     (consumed by Track A1's conversation-id detector).
#
# agy has no native Claude-style SessionStart hook surface; the launch-time
# `agy -i <bootstrap-prompt>` form is the SessionStart-injection analogue.
# Depends on lib/bridge-core.sh (bridge_join_quoted, bridge_require_python,
# bridge_resolve_script_dir_check) and is sourced by bridge-lib.sh after
# bridge-core.sh / bridge-agents.sh and before bridge-state.sh /
# bridge-skills.sh which call into it.

# --- agy config / conversation-state paths -------------------------------

# Root of the agy CLI config + conversation state. Honors GEMINI_HOME for
# isolated tests; defaults to ~/.gemini.
bridge_antigravity_config_root() {
  printf '%s/antigravity-cli' "${GEMINI_HOME:-$HOME/.gemini}"
}

# Path to the agy settings.json (trust + permissions + altScreenMode).
bridge_antigravity_settings_file() {
  printf '%s/settings.json' "$(bridge_antigravity_config_root)"
}

# Directory holding per-conversation state. Track A1 builds its
# conversation-id detector on top of this helper — keep it stable.
bridge_antigravity_conversation_state_dir() {
  printf '%s/conversations' "$(bridge_antigravity_config_root)"
}

# Path to the agy conversation history index (one JSON object per line).
# Also consumed by Track A1's detector.
bridge_antigravity_history_file() {
  printf '%s/history.jsonl' "$(bridge_antigravity_config_root)"
}

# --- settings / trust preseed --------------------------------------------

# bridge_antigravity_settings_preseed <workdir>
#
# Atomic read-modify-write of the agy settings.json: add <workdir> to
# trustedWorkspaces (pre-empts the trust selector), add the bridge CLIs to
# permissions.allow, and pin altScreenMode=always. All pre-existing keys
# are preserved; idempotent. Runs BEFORE launch — not a reactive tmux
# workaround. The JSON mutation is done by a standalone python helper
# invoked file-as-argv (no heredoc-stdin — footgun #11).
bridge_antigravity_settings_preseed() {
  local workdir="$1"
  local settings_file agb_path agent_bridge_path

  if [[ -z "$workdir" ]]; then
    bridge_warn "antigravity settings preseed: empty workdir; skipping."
    return 1
  fi

  bridge_require_python
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi

  settings_file="$(bridge_antigravity_settings_file)"
  # The bridge CLIs live in the live runtime root ($BRIDGE_HOME), which is
  # what an agy agent invokes (`~/.agent-bridge/agb`, `agent-bridge`).
  agb_path="$BRIDGE_HOME/agb"
  agent_bridge_path="$BRIDGE_HOME/agent-bridge"

  python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/antigravity-settings-preseed.py" \
    "$settings_file" "$workdir" "$agb_path" "$agent_bridge_path"
}

# --- launch-time bootstrap prompt ----------------------------------------

# bridge_antigravity_bootstrap_prompt <agent>
#
# The `-i` bootstrap prompt — the SessionStart-injection analogue for agy.
# It points the agent at its on-disk context (SOUL.md / CLAUDE.md in the
# workdir) and the queue signal (`agb inbox <agent>`), mirroring the intent
# of the Claude SessionStart hook (hooks/bridge_hook_common.py
# session_start_context). Emitted as a single well-formed line so it quotes
# cleanly into the launch argv.
bridge_antigravity_bootstrap_prompt() {
  local agent="$1"
  local inbox_cli="${BRIDGE_HOME:-$HOME/.agent-bridge}/agb"

  printf '%s' \
"[Agent Bridge] You are the managed agent '${agent}'. Before any other work: \
read SOUL.md and CLAUDE.md in this working directory for your role and \
project context, then run exactly '${inbox_cli} inbox ${agent}' to pull \
your queued tasks. Use the agent-bridge queue (claim / done) for all \
inter-agent work; reserve urgent sends for true interrupts."
}

# --- launch-command builder ----------------------------------------------

# bridge_antigravity_dynamic_launch_cmd <agent> <continue> <session_id>
#
# Builds the agy launch argv:
#   fresh  : agy --dangerously-skip-permissions -i <bootstrap-prompt>
#   resume : agy --dangerously-skip-permissions --conversation <session_id>
#
# The `-i` bootstrap is for FRESH sessions only. A resumed conversation
# already carries its prior context, so the resume form skips `-i` — this
# mirrors how the claude/codex resume builders skip fresh-session bootstrap
# (bridge-state.sh bridge_build_resume_launch_cmd). Resume is selected only
# when continue=1 AND a non-empty session_id is supplied.
bridge_antigravity_dynamic_launch_cmd() {
  local agent="$1"
  local continue_mode="$2"
  local session_id="$3"

  if [[ "$continue_mode" == "1" && -n "$session_id" ]]; then
    bridge_join_quoted agy --dangerously-skip-permissions \
      --conversation "$session_id"
    return 0
  fi

  bridge_join_quoted agy --dangerously-skip-permissions \
    -i "$(bridge_antigravity_bootstrap_prompt "$agent")"
}
