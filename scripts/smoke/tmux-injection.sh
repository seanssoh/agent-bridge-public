#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="tmux-injection"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

source_bridge_lib() {
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
}

tmux_pending_input_detection() {
  if ! bridge_tmux_session_has_pending_input_from_text claude $'quoted scrollback\n> typed but not submitted'; then
    smoke_fail "tmux pending-input detection: expected Claude prompt text to be busy"
  fi
  if bridge_tmux_session_has_pending_input_from_text claude $'>\n'; then
    smoke_fail "tmux pending-input detection: empty Claude prompt was treated as busy"
  fi
  if bridge_tmux_session_has_pending_input_from_text claude $'> old scrollback\nassistant response\n❯ '; then
    smoke_fail "tmux pending-input detection: old scrollback prompt overrode final empty prompt"
  fi
  if ! bridge_tmux_session_has_pending_input_from_text claude \
      $'assistant response\n❯ 응답 오면 알려줘' \
      $'assistant response\n\e[39m❯ \e[97m응답 오면 알려줘\e[39m'; then
    smoke_fail "tmux pending-input detection: expected real Claude prompt text to be busy"
  fi
  if bridge_tmux_session_has_pending_input_from_text claude \
      $'assistant response\n❯ 응답 오면 알려줘' \
      $'assistant response\n\e[39m❯ \e[7m응\e[0;2m답 오면 알려줘\e[0m\e[39m'; then
    smoke_fail "tmux pending-input detection: Claude dim ghost text was treated as busy"
  fi
  if ! bridge_tmux_session_has_pending_input_from_text codex $'› operator draft'; then
    smoke_fail "tmux pending-input detection: expected Codex prompt text to be busy"
  fi
  if bridge_tmux_session_has_pending_input_from_text codex $'› old draft\noutput\n› '; then
    smoke_fail "tmux pending-input detection: old Codex scrollback overrode final empty prompt"
  fi
}

tmux_attention_payload_contract() {
  local default_text meta_text newline_count

  default_text="$(bridge_queue_attention_message "smoke-agent" 2 7 urgent "fix queue")"
  smoke_assert_contains "$default_text" "ACTION REQUIRED" "legacy queue attention payload"
  smoke_assert_contains "$default_text" "Task #7 [urgent] fix queue" "legacy queue attention task metadata"

  meta_text="$(BRIDGE_INJECT_METADATA_ONLY=1 bridge_queue_attention_message "smoke-agent" 2 7 urgent "fix queue")"
  smoke_assert_contains "$meta_text" "[Agent Bridge] event=inbox" "metadata-only queue attention payload"
  smoke_assert_contains "$meta_text" "agent=smoke-agent" "metadata-only queue attention agent"
  smoke_assert_not_contains "$meta_text" "ACTION REQUIRED" "metadata-only payload avoids execution verb"
  newline_count="$(printf '%s' "$meta_text" | wc -l | tr -d '[:space:]')"
  smoke_assert_eq "0" "$newline_count" "metadata-only queue attention payload stays single-line/no trailing newline"
}

tmux_pending_spool_contract() {
  local agent drained count head

  agent="spool-agent"
  bridge_tmux_pending_attention_append "$agent" "first"
  bridge_tmux_pending_attention_append "$agent" $'second\nwith-newline'
  count="$(bridge_tmux_pending_attention_count "$agent")"
  smoke_assert_eq "2" "$count" "pending attention append count"

  drained="$(bridge_tmux_pending_attention_drain "$agent")"
  smoke_assert_contains "$drained" "first" "pending attention drain preserves first entry"
  smoke_assert_contains "$drained" "second" "pending attention drain preserves multiline entry"
  count="$(bridge_tmux_pending_attention_count "$agent")"
  smoke_assert_eq "0" "$count" "pending attention drain empties spool"

  bridge_tmux_pending_attention_append "$agent" "new"
  bridge_tmux_pending_attention_prepend "$agent" $'old\n'
  head="$(bridge_tmux_pending_attention_drain "$agent" | head -n 1)"
  smoke_assert_eq "old" "$head" "pending attention prepend order"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "tmux-injection"
  source_bridge_lib
  smoke_run "pending input classifier" tmux_pending_input_detection
  smoke_run "queue attention payload formats" tmux_attention_payload_contract
  smoke_run "pending attention spool" tmux_pending_spool_contract
  smoke_log "passed"
}

main "$@"
