#!/usr/bin/env bash
# bridge-setup.sh — guided onboarding for channel-backed agents

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") discord <agent> [--token <token>] [--channel-account <account>] [--runtime-config <path>] [--channel <id>]... [--allow-from <id>]... [--require-mention] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
  $(basename "$0") telegram <agent> [--token <token>] [--channel-account <account>] [--runtime-config <path>] [--allow-from <id>]... [--default-chat <id>] [--test-chat <id>] [--use-relay] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
  $(basename "$0") teams <agent> [--app-id <id>] [--app-password <secret>] [--tenant-id <id>] [--channel-account <account>] [--runtime-config <path>] [--messaging-endpoint <url>] [--webhook-host <host>] [--webhook-port <port>] [--ingress-port <port>] [--allow-from <id>]... [--conversation <id>]... [--require-mention] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
  $(basename "$0") agent <agent> [--skip-discord] [--skip-telegram] [--skip-teams] [--test-start] [setup options...]
  $(basename "$0") admin <agent>

Examples:
  $(basename "$0") discord tester
  $(basename "$0") discord tester --channel-account default --channel 123456789012345678
  $(basename "$0") telegram tester --channel-account default --allow-from 123456789
  $(basename "$0") teams tester --channel-account default --allow-from 00000000-0000-0000-0000-000000000000
  $(basename "$0") agent tester
  $(basename "$0") agent tester --test-start
  $(basename "$0") admin tester
EOF
}

setup_subcommand_usage() {
  local subcommand="$1"
  case "$subcommand" in
    discord)
      cat <<EOF
Usage:
  $(basename "$0") discord <agent> [--token <token>] [--channel-account <account>] [--runtime-config <path>] [--channel <id>]... [--allow-from <id>]... [--require-mention] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
EOF
      ;;
    telegram)
      cat <<EOF
Usage:
  $(basename "$0") telegram <agent> [--token <token>] [--channel-account <account>] [--runtime-config <path>] [--allow-from <id>]... [--default-chat <id>] [--test-chat <id>] [--use-relay] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
EOF
      ;;
    teams)
      cat <<EOF
Usage:
  $(basename "$0") teams <agent> [--app-id <id>] [--app-password <secret>] [--tenant-id <id>] [--channel-account <account>] [--runtime-config <path>] [--messaging-endpoint <url>] [--webhook-host <host>] [--webhook-port <port>] [--ingress-port <port>] [--allow-from <id>]... [--conversation <id>]... [--require-mention] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
EOF
      ;;
    agent)
      cat <<EOF
Usage:
  $(basename "$0") agent <agent> [--skip-discord] [--skip-telegram] [--skip-teams] [--test-start] [setup options...]
EOF
      ;;
    admin)
      cat <<EOF
Usage:
  $(basename "$0") admin <agent>
EOF
      ;;
    *)
      usage
      ;;
  esac
}

bridge_setup_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-setup.py" "$@"
}

bridge_find_agent_claude_md() {
  local agent="$1"
  local target_root=""
  local candidate
  local candidates=()

  if bridge_profile_has_source "$agent"; then
    candidates+=("$(bridge_profile_source_root "$agent")/CLAUDE.md")
  fi

  target_root="$(bridge_resolve_profile_target "$agent" || true)"
  if [[ -n "$target_root" ]]; then
    candidates+=("$target_root/CLAUDE.md")
  fi

  candidates+=("$(bridge_agent_workdir "$agent")/CLAUDE.md")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

bridge_setup_primary_access_channel() {
  local discord_dir="$1"

  bridge_require_python
  python3 - "$discord_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

groups = payload.get("groups") or {}
for channel_id in groups.keys():
    channel_id = str(channel_id).strip()
    if channel_id:
        print(channel_id)
        break
PY
}

bridge_setup_access_channels() {
  local discord_dir="$1"

  bridge_require_python
  python3 - "$discord_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

groups = payload.get("groups") or {}
for channel_id in groups.keys():
    channel_id = str(channel_id).strip()
    if channel_id:
        print(channel_id)
PY
}

bridge_setup_telegram_allow_from() {
  local telegram_dir="$1"

  bridge_require_python
  python3 - "$telegram_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

for item in payload.get("allowFrom") or []:
    value = str(item).strip()
    if value:
        print(value)
PY
}

bridge_setup_telegram_default_chat() {
  local telegram_dir="$1"

  bridge_require_python
  python3 - "$telegram_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

value = str(payload.get("defaultChatId") or "").strip()
if value:
    print(value)
PY
}

bridge_setup_teams_allow_from() {
  local teams_dir="$1"

  bridge_require_python
  python3 - "$teams_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

for item in payload.get("allowFrom") or []:
    value = str(item).strip()
    if value:
        print(value)
PY
}

bridge_setup_teams_conversations() {
  local teams_dir="$1"

  bridge_require_python
  python3 - "$teams_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

groups = payload.get("groups") or {}
for conversation_id in groups.keys():
    conversation_id = str(conversation_id).strip()
    if conversation_id:
        print(conversation_id)
PY
}

bridge_setup_write_local_scalar() {
  local key="$1"
  local value="$2"

  bridge_require_python
  python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$key" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
line = f'{key}="{value}"'

if path.exists():
    text = path.read_text(encoding="utf-8")
else:
    text = "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"

pattern = re.compile(rf'(?m)^[ \t]*{re.escape(key)}=.*$')
if pattern.search(text):
    text = pattern.sub(line, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += line + "\n"

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text, encoding="utf-8")
print(f"updated: {path}")
print(f"{key}={value}")
PY
}

bridge_setup_write_local_assoc() {
  local key="$1"
  local assoc_key="$2"
  local value="$3"

  bridge_require_python
  python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$key" "$assoc_key" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
assoc_key = sys.argv[3]
value = sys.argv[4]
line = f'{key}["{assoc_key}"]="{value}"'

if path.exists():
    text = path.read_text(encoding="utf-8")
else:
    text = "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"

pattern = re.compile(rf'(?m)^[ \t]*{re.escape(key)}\["{re.escape(assoc_key)}"\]=.*$')
if pattern.search(text):
    text = pattern.sub(line, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += line + "\n"

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text, encoding="utf-8")
print(f"updated: {path}")
print(f'{key}["{assoc_key}"]={value}')
PY
}

bridge_setup_sync_runtime_account() {
  local source_config="$1"
  local target_config="$2"
  local kind="$3"
  local account="$4"

  [[ -n "$source_config" && -n "$target_config" && -n "$kind" && -n "$account" ]] || return 0
  if [[ "$source_config" == "$target_config" ]]; then
    return 0
  fi

  bridge_require_python
  python3 - "$source_config" "$target_config" "$kind" "$account" <<'PY'
from pathlib import Path
import json
import sys

source_path = Path(sys.argv[1]).expanduser()
target_path = Path(sys.argv[2]).expanduser()
kind = sys.argv[3]
account = sys.argv[4]

if not source_path.exists():
    raise SystemExit(0)

with source_path.open("r", encoding="utf-8") as handle:
    source_payload = json.load(handle)

account_cfg = (((source_payload.get("channels") or {}).get(kind) or {}).get("accounts") or {}).get(account)
if not isinstance(account_cfg, dict):
    raise SystemExit(0)

if target_path.exists():
    with target_path.open("r", encoding="utf-8") as handle:
        target_payload = json.load(handle)
else:
    target_payload = {}

channels = target_payload.setdefault("channels", {})
channel_cfg = channels.setdefault(kind, {})
accounts = channel_cfg.setdefault("accounts", {})
accounts[account] = account_cfg

target_path.parent.mkdir(parents=True, exist_ok=True)
tmp = target_path.with_suffix(target_path.suffix + ".tmp")
with tmp.open("w", encoding="utf-8") as handle:
    json.dump(target_payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
tmp.chmod(0o600)
tmp.replace(target_path)
target_path.chmod(0o600)
PY
}

bridge_setup_require_claude_agent() {
  local agent="$1"
  local kind="$2"

  if [[ "$(bridge_agent_engine "$agent")" != "claude" ]]; then
    bridge_die "$kind channel setup requires a Claude Code agent. Current engine for '$agent': $(bridge_agent_engine "$agent")"
  fi
}

bridge_setup_add_agent_channel() {
  local agent="$1"
  local channel="$2"
  local current=""
  local merged=""

  channel="$(bridge_qualify_channel_item "$channel")"
  current="$(bridge_agent_channels_csv "$agent")"
  merged="$(bridge_merge_channels_csv "$current" "$channel")"
  bridge_setup_write_local_assoc "BRIDGE_AGENT_CHANNELS" "$agent" "$merged" >/dev/null
  BRIDGE_AGENT_CHANNELS["$agent"]="$merged"
}

bridge_setup_replace_agent_telegram_channel() {
  local agent="$1"
  local channel="$2"
  local current=""
  local filtered=""
  local item=""
  local merged=""
  local -a items=()

  channel="$(bridge_qualify_channel_item "$channel")"
  current="$(bridge_agent_channels_csv "$agent")"
  IFS=',' read -r -a items <<<"$current"
  for item in "${items[@]}"; do
    item="$(bridge_qualify_channel_item "$item")"
    [[ -n "$item" ]] || continue
    case "$item" in
      plugin:telegram@claude-plugins-official|plugin:telegram-relay@agent-bridge|plugin:telegram-relay@*)
        continue
        ;;
    esac
    filtered="$(bridge_merge_channels_csv "$filtered" "$item")"
  done

  merged="$(bridge_merge_channels_csv "$filtered" "$channel")"
  bridge_setup_write_local_assoc "BRIDGE_AGENT_CHANNELS" "$agent" "$merged" >/dev/null
  BRIDGE_AGENT_CHANNELS["$agent"]="$merged"
}

bridge_setup_ensure_development_channels_launch_flag() {
  local agent="$1"
  local current=""
  local updated=""
  local dev_channels=""

  current="$(bridge_agent_launch_cmd_raw "$agent")"
  [[ -n "$current" ]] || return 1

  dev_channels="$(bridge_agent_dev_channels_csv "$agent")"
  updated="$(bridge_claude_launch_with_development_channels "$current" "$dev_channels")"
  if [[ "$updated" == "$current" ]]; then
    return 1
  fi

  bridge_setup_write_local_assoc "BRIDGE_AGENT_LAUNCH_CMD" "$agent" "$updated" >/dev/null
  BRIDGE_AGENT_LAUNCH_CMD["$agent"]="$updated"
  return 0
}

run_discord() {
  local agent="${1:-}"
  local workdir=""
  local discord_dir=""
  local suggested_channel=""
  local runtime_config=""
  local compat_config=""
  local channel_account=""
  local primary_channel=""
  local dry_run=0
  local py_args=()
  local base_args=()

  shift || true
  if [[ "$agent" == "-h" || "$agent" == "--help" || "$agent" == "help" ]]; then
    setup_subcommand_usage "discord"
    return 0
  fi
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") discord <agent> [...]"
  bridge_require_agent "$agent"
  bridge_setup_require_claude_agent "$agent" "Discord"
  runtime_config="$(bridge_compat_config_file)"
  compat_config="$(bridge_compat_config_file)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token|--channel-account|--openclaw-account|--runtime-config|--openclaw-config|--channel|--allow-from|--api-base-url)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ "$1" == "--channel-account" || "$1" == "--openclaw-account" ]]; then
          channel_account="$2"
        fi
        if [[ "$1" == "--channel" && -z "$primary_channel" ]]; then
          primary_channel="$2"
        fi
        if [[ "$1" == "--runtime-config" || "$1" == "--openclaw-config" ]]; then
          runtime_config="$2"
        fi
        py_args+=("$1" "$2")
        shift 2
        ;;
      --require-mention|--skip-validate|--skip-send-test|--yes|--dry-run)
        [[ "$1" == "--dry-run" ]] && dry_run=1
        py_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 setup discord 옵션입니다: $1"
        ;;
    esac
  done

  workdir="$(bridge_agent_workdir "$agent")"
  discord_dir="$(bridge_agent_discord_state_dir "$agent")"
  suggested_channel="$(bridge_agent_discord_channel_id "$agent")"
  base_args=(
    discord
    --agent "$agent"
    --discord-dir "$discord_dir"
    --runtime-config "$runtime_config"
  )
  if [[ -n "$suggested_channel" ]]; then
    base_args+=(--suggested-channel "$suggested_channel")
  fi

  bridge_setup_python "${base_args[@]}" "${py_args[@]}"
  if [[ $dry_run -eq 0 ]]; then
    bridge_setup_add_agent_channel "$agent" "plugin:discord"
    if [[ -n "$primary_channel" ]]; then
      bridge_setup_write_local_assoc "BRIDGE_AGENT_DISCORD_CHANNEL_ID" "$agent" "$primary_channel" >/dev/null
    fi
    if [[ -n "$channel_account" ]]; then
      bridge_setup_sync_runtime_account "$runtime_config" "$compat_config" "discord" "$channel_account"
      bridge_setup_write_local_assoc "BRIDGE_AGENT_NOTIFY_ACCOUNT" "$agent" "$channel_account" >/dev/null
    fi
    bridge_ensure_claude_channel_plugins "$agent"
  fi
}

run_telegram() {
  local agent="${1:-}"
  local workdir=""
  local telegram_dir=""
  local runtime_config=""
  local compat_config=""
  local channel_account=""
  local dry_run=0
  local use_relay=0
  local py_args=()
  local base_args=()

  shift || true
  if [[ "$agent" == "-h" || "$agent" == "--help" || "$agent" == "help" ]]; then
    setup_subcommand_usage "telegram"
    return 0
  fi
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") telegram <agent> [...]"
  bridge_require_agent "$agent"
  bridge_setup_require_claude_agent "$agent" "Telegram"
  runtime_config="$(bridge_compat_config_file)"
  compat_config="$(bridge_compat_config_file)"
  case "${BRIDGE_TELEGRAM_USE_RELAY:-}" in
    1|true|TRUE|yes|YES|on|ON)
      use_relay=1
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token|--channel-account|--openclaw-account|--runtime-config|--openclaw-config|--allow-from|--default-chat|--test-chat|--api-base-url)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ "$1" == "--channel-account" || "$1" == "--openclaw-account" ]]; then
          channel_account="$2"
        fi
        if [[ "$1" == "--runtime-config" || "$1" == "--openclaw-config" ]]; then
          runtime_config="$2"
        fi
        py_args+=("$1" "$2")
        shift 2
        ;;
      --skip-validate|--skip-send-test|--yes|--dry-run)
        [[ "$1" == "--dry-run" ]] && dry_run=1
        py_args+=("$1")
        shift
        ;;
      --use-relay)
        use_relay=1
        py_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 setup telegram 옵션입니다: $1"
        ;;
    esac
  done

  workdir="$(bridge_agent_workdir "$agent")"
  telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
  base_args=(
    telegram
    --agent "$agent"
    --telegram-dir "$telegram_dir"
    --runtime-config "$runtime_config"
    --bridge-state-dir "$BRIDGE_STATE_DIR"
  )

  bridge_setup_python "${base_args[@]}" "${py_args[@]}"
  if [[ $dry_run -eq 0 ]]; then
    if [[ $use_relay -eq 1 ]]; then
      bridge_setup_replace_agent_telegram_channel "$agent" "plugin:telegram-relay@agent-bridge"
      bridge_setup_write_local_scalar "BRIDGE_TELEGRAM_RELAY_ENABLED" "1" >/dev/null
      BRIDGE_TELEGRAM_RELAY_ENABLED=1
      if bridge_setup_ensure_development_channels_launch_flag "$agent"; then
        bridge_info "[info] added --dangerously-load-development-channels $(bridge_agent_dev_channels_csv "$agent") to $agent launch"
      else
        bridge_info "[info] $agent launch already allows development channels: $(bridge_agent_dev_channels_csv "$agent")"
      fi
    else
      bridge_setup_add_agent_channel "$agent" "plugin:telegram"
    fi
    if [[ -n "$channel_account" ]]; then
      bridge_setup_sync_runtime_account "$runtime_config" "$compat_config" "telegram" "$channel_account"
      bridge_setup_write_local_assoc "BRIDGE_AGENT_NOTIFY_ACCOUNT" "$agent" "$channel_account" >/dev/null
    fi
    bridge_ensure_claude_channel_plugins "$agent"
  fi
}

run_teams() {
  local agent="${1:-}"
  local teams_dir=""
  local runtime_config=""
  local compat_config=""
  local channel_account=""
  local dry_run=0
  local py_args=()
  local base_args=()

  shift || true
  if [[ "$agent" == "-h" || "$agent" == "--help" || "$agent" == "help" ]]; then
    setup_subcommand_usage "teams"
    return 0
  fi
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") teams <agent> [...]"
  bridge_require_agent "$agent"
  bridge_setup_require_claude_agent "$agent" "Teams"
  runtime_config="$(bridge_compat_config_file)"
  compat_config="$(bridge_compat_config_file)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-id|--app-password|--tenant-id|--service-url|--messaging-endpoint|--webhook-host|--webhook-port|--ingress-port|--channel-account|--runtime-config|--allow-from|--conversation)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ "$1" == "--channel-account" ]]; then
          channel_account="$2"
        fi
        if [[ "$1" == "--runtime-config" ]]; then
          runtime_config="$2"
        fi
        py_args+=("$1" "$2")
        shift 2
        ;;
      --require-mention|--skip-validate|--skip-send-test|--yes|--dry-run)
        [[ "$1" == "--dry-run" ]] && dry_run=1
        py_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 setup teams 옵션입니다: $1"
        ;;
    esac
  done

  teams_dir="$(bridge_agent_teams_state_dir "$agent")"
  base_args=(
    teams
    --agent "$agent"
    --teams-dir "$teams_dir"
    --runtime-config "$runtime_config"
  )

  bridge_setup_python "${base_args[@]}" "${py_args[@]}"
  if [[ $dry_run -eq 0 ]]; then
    bridge_setup_add_agent_channel "$agent" "plugin:teams"
    if bridge_setup_ensure_development_channels_launch_flag "$agent"; then
      bridge_info "[info] added --dangerously-load-development-channels $(bridge_agent_dev_channels_csv "$agent") to $agent launch"
    else
      bridge_info "[info] $agent launch already allows development channels: $(bridge_agent_dev_channels_csv "$agent")"
    fi
    if [[ -n "$channel_account" ]]; then
      bridge_setup_sync_runtime_account "$runtime_config" "$compat_config" "teams" "$channel_account"
      bridge_setup_write_local_assoc "BRIDGE_AGENT_NOTIFY_ACCOUNT" "$agent" "$channel_account" >/dev/null
    fi
    bridge_ensure_claude_channel_plugins "$agent"
  fi
}

run_agent() {
  local agent="${1:-}"
  local skip_discord=0
  local skip_telegram=0
  local skip_teams=0
  local test_start=0
  local failures=0
  local warnings=()
  local discord_args=()
  local telegram_args=()
  local teams_args=()
  local engine=""
  local session=""
  local workdir=""
  local profile_target=""
  local claude_path=""
  local hook_output=""
  local prompt_hook_output=""
  local webhook_cleanup_output=""
  local wake_status=""
  local settings_mode=""
  local roster_channel=""
  local access_channel=""
  local access_channels=()
  local required_channels=""
  local channel_status=""
  local channel_reason=""
  local start_output=""
  local telegram_dir=""
  local telegram_default_chat=""
  local telegram_allow_from=()
  local teams_dir=""
  local teams_allow_from=()
  local teams_conversations=()

  shift || true
  if [[ "$agent" == "-h" || "$agent" == "--help" || "$agent" == "help" ]]; then
    setup_subcommand_usage "agent"
    return 0
  fi
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") agent <agent> [...]"
  bridge_require_agent "$agent"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-discord)
        skip_discord=1
        shift
        ;;
      --skip-telegram)
        skip_telegram=1
        shift
        ;;
      --skip-teams)
        skip_teams=1
        shift
        ;;
      --test-start)
        test_start=1
        shift
        ;;
      --channel|--require-mention)
        if [[ "$1" == "--channel" ]]; then
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          discord_args+=("$1" "$2")
          shift 2
        else
          discord_args+=("$1")
          shift
        fi
        ;;
      --default-chat|--test-chat)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        telegram_args+=("$1" "$2")
        shift 2
        ;;
      --conversation|--app-id|--app-password|--tenant-id|--service-url|--messaging-endpoint|--webhook-host|--webhook-port|--ingress-port)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        teams_args+=("$1" "$2")
        shift 2
        ;;
      --token|--channel-account|--openclaw-account|--runtime-config|--openclaw-config|--allow-from|--api-base-url)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        discord_args+=("$1" "$2")
        telegram_args+=("$1" "$2")
        case "$1" in
          --channel-account|--runtime-config|--allow-from)
            teams_args+=("$1" "$2")
            ;;
        esac
        shift 2
        ;;
      --require-mention|--skip-validate|--skip-send-test|--yes|--dry-run)
        discord_args+=("$1")
        telegram_args+=("$1")
        teams_args+=("$1")
        shift
        ;;
      --use-relay)
        telegram_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 setup agent 옵션입니다: $1"
        ;;
    esac
  done

  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  profile_target="$(bridge_resolve_profile_target "$agent" || true)"
  wake_status="$(bridge_agent_wake_status "$agent")"
  required_channels="$(bridge_agent_channels_csv "$agent")"
  channel_status="$(bridge_agent_channel_status "$agent")"
  channel_reason="$(bridge_agent_channel_status_reason "$agent")"
  roster_channel="$(bridge_agent_discord_channel_id "$agent")"
  access_channel="$(bridge_setup_primary_access_channel "$(bridge_agent_discord_state_dir "$agent")" || true)"
  mapfile -t access_channels < <(bridge_setup_access_channels "$(bridge_agent_discord_state_dir "$agent")" || true)
  telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
  telegram_default_chat="$(bridge_setup_telegram_default_chat "$telegram_dir" || true)"
  mapfile -t telegram_allow_from < <(bridge_setup_telegram_allow_from "$telegram_dir" || true)
  teams_dir="$(bridge_agent_teams_state_dir "$agent")"
  mapfile -t teams_allow_from < <(bridge_setup_teams_allow_from "$teams_dir" || true)
  mapfile -t teams_conversations < <(bridge_setup_teams_conversations "$teams_dir" || true)

  if [[ $skip_discord -eq 0 ]] && bridge_channel_csv_contains "$required_channels" "plugin:discord"; then
    echo "== Discord setup =="
    if ! run_discord "$agent" "${discord_args[@]}"; then
      failures=$((failures + 1))
    fi
    echo
    access_channel="$(bridge_setup_primary_access_channel "$(bridge_agent_discord_state_dir "$agent")" || true)"
    mapfile -t access_channels < <(bridge_setup_access_channels "$(bridge_agent_discord_state_dir "$agent")" || true)
  fi

  if [[ $skip_telegram -eq 0 ]] \
      && { bridge_channel_csv_contains "$required_channels" "plugin:telegram" \
        || bridge_channel_csv_contains "$required_channels" "plugin:telegram-relay"; }; then
    echo "== Telegram setup =="
    if ! run_telegram "$agent" "${telegram_args[@]}"; then
      failures=$((failures + 1))
    fi
    echo
    telegram_default_chat="$(bridge_setup_telegram_default_chat "$telegram_dir" || true)"
    mapfile -t telegram_allow_from < <(bridge_setup_telegram_allow_from "$telegram_dir" || true)
  fi

  if [[ $skip_teams -eq 0 ]] && bridge_channel_csv_contains "$required_channels" "plugin:teams"; then
    echo "== Teams setup =="
    if ! run_teams "$agent" "${teams_args[@]}"; then
      failures=$((failures + 1))
    fi
    echo
    mapfile -t teams_allow_from < <(bridge_setup_teams_allow_from "$teams_dir" || true)
    mapfile -t teams_conversations < <(bridge_setup_teams_conversations "$teams_dir" || true)
  fi

  echo "== Agent preflight =="
  printf 'agent: %s\n' "$agent"
  printf 'engine: %s\n' "$engine"
  printf 'session: %s\n' "$session"
  printf 'workdir: %s\n' "$workdir"
  printf 'discord_dir: %s\n' "$(bridge_agent_discord_state_dir "$agent")"
  printf 'telegram_dir: %s\n' "$telegram_dir"
  printf 'teams_dir: %s\n' "$teams_dir"
  if [[ -n "$required_channels" ]]; then
    printf 'required_channels: %s\n' "$required_channels"
  else
    printf 'required_channels: (unset)\n'
  fi
  if [[ -n "$roster_channel" ]]; then
    printf 'roster_discord_channel: %s\n' "$roster_channel"
  else
    printf 'roster_discord_channel: (unset)\n'
  fi
  if [[ -n "$telegram_default_chat" ]]; then
    printf 'telegram_default_chat: %s\n' "$telegram_default_chat"
  else
    printf 'telegram_default_chat: (unset)\n'
  fi
  if [[ ${#telegram_allow_from[@]} -gt 0 ]]; then
    printf 'telegram_allow_from: %s\n' "$(IFS=,; echo "${telegram_allow_from[*]}")"
  else
    printf 'telegram_allow_from: (none)\n'
  fi
  if [[ ${#teams_allow_from[@]} -gt 0 ]]; then
    printf 'teams_allow_from: %s\n' "$(IFS=,; echo "${teams_allow_from[*]}")"
  else
    printf 'teams_allow_from: (none)\n'
  fi
  if [[ ${#teams_conversations[@]} -gt 0 ]]; then
    printf 'teams_conversations: %s\n' "$(IFS=,; echo "${teams_conversations[*]}")"
  else
    printf 'teams_conversations: (none)\n'
  fi
  printf 'wake_channel: %s\n' "$wake_status"
  printf 'channel_status: %s\n' "$channel_status"

  if [[ "$engine" == "claude" ]]; then
    echo
    echo "== Claude Skills =="
    bridge_ensure_project_claude_guidance "$workdir" >/dev/null 2>&1 || true
    bridge_bootstrap_project_skill "$engine" "$workdir" >/dev/null 2>&1 || true
    bridge_bootstrap_claude_shared_skills "$agent" "$workdir" >/dev/null 2>&1 || true
    bridge_sync_skill_docs "$agent" >/dev/null 2>&1 || true
    printf 'claude_bridge_guidance: %s\n' "$workdir/CLAUDE.md"
    printf 'project_skill: %s\n' "$workdir/.claude/skills/agent-bridge/SKILL.md"
    printf 'runtime_skill: %s\n' "$workdir/.claude/skills/agent-bridge-runtime/SKILL.md"
    printf 'cron_skill: %s\n' "$workdir/.claude/skills/cron-manager/SKILL.md"
    if [[ -n "$(bridge_agent_skills_csv "$agent")" ]]; then
      printf 'configured_runtime_skills: %s\n' "$(bridge_agent_skills_csv "$agent")"
    else
      printf 'configured_runtime_skills: (none)\n'
    fi

    echo
    echo "== Claude Activity Hooks =="
    settings_mode="$(bridge_claude_settings_mode "$workdir")"
    printf 'settings_mode: %s\n' "$settings_mode"
    if [[ "$settings_mode" == "shared" ]]; then
      printf 'shared_settings_base_file: %s\n' "$(bridge_hook_shared_settings_base_file)"
      printf 'shared_settings_effective_file: %s\n' "$(bridge_hook_shared_settings_effective_file)"
    fi
    if hook_output="$(bridge_ensure_claude_stop_hook "$workdir" 2>&1)"; then
      echo "$hook_output"
    else
      echo "$hook_output"
      failures=$((failures + 1))
    fi
    if prompt_hook_output="$(bridge_ensure_claude_prompt_hook "$workdir" 2>&1)"; then
      echo "$prompt_hook_output"
    else
      echo "$prompt_hook_output"
      failures=$((failures + 1))
    fi

    echo
    echo "== Claude Idle Wake =="
    echo "mode: local_tmux_send"
    echo "idle_marker: stop_hook + prompt_hook"
    if webhook_cleanup_output="$(bridge_disable_claude_webhook_channel "$agent" "$workdir" 2>&1)"; then
      echo "$webhook_cleanup_output"
    else
      echo "$webhook_cleanup_output"
      warnings+=("Legacy bridge-webhook MCP entry could not be removed automatically from $workdir/.mcp.json. Remove it manually before restarting the session.")
    fi

    claude_path="$(bridge_find_agent_claude_md "$agent" || true)"
    if [[ -n "$claude_path" ]]; then
      printf 'claude_md: ok (%s)\n' "$claude_path"
    else
      printf 'claude_md: missing\n'
      failures=$((failures + 1))
      warnings+=("Add a CLAUDE.md file in the tracked profile or live workdir before cutover.")
    fi
  elif [[ "$engine" == "codex" ]]; then
    echo
    echo "== Codex Skills =="
    bridge_bootstrap_project_skill "$engine" "$workdir" >/dev/null 2>&1 || true
    bridge_sync_skill_docs "$agent" >/dev/null 2>&1 || true
    printf 'project_skill: %s\n' "$workdir/.codex/skills/agent-bridge/SKILL.md"

    echo
    echo "== Codex Hooks =="
    if hook_output="$(bridge_ensure_codex_hooks 2>&1)"; then
      echo "$hook_output"
    else
      echo "$hook_output"
      failures=$((failures + 1))
    fi
    printf 'claude_md: n/a (engine=%s)\n' "$engine"
  else
    printf 'claude_md: n/a (engine=%s)\n' "$engine"
  fi

  if bridge_profile_has_source "$agent"; then
    echo
    echo "== Profile status =="
    if ! "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-profile.sh" status "$agent"; then
      failures=$((failures + 1))
    fi
  else
    echo
    echo "== Profile status =="
    if [[ -n "$profile_target" ]]; then
      printf 'tracked_profile: no\n'
      printf 'profile_target: %s\n' "$profile_target"
    else
      printf 'tracked_profile: no\n'
      printf 'profile_target: (unset)\n'
    fi
  fi

  echo
  echo "== Start dry-run =="
  if start_output="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --dry-run 2>&1)"; then
    echo "start_dry_run: ok"
    echo "$start_output"
  else
    echo "start_dry_run: error"
    echo "$start_output"
    failures=$((failures + 1))
  fi

  if [[ $test_start -eq 1 ]]; then
    echo
    echo "== Session smoke =="
    if bridge_tmux_session_exists "$session"; then
      echo "session_smoke: already_active (left running)"
    else
      if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
        sleep 1
        if bridge_tmux_session_exists "$session"; then
          echo "session_smoke: ok"
          bridge_tmux_kill_session "$session" >/dev/null 2>&1 || true
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
          echo "session_smoke_cleanup: stopped"
        else
          echo "session_smoke: failed (tmux session did not stay up)"
          failures=$((failures + 1))
        fi
      else
        echo "session_smoke: failed (bridge-start returned non-zero)"
        failures=$((failures + 1))
      fi
    fi
  fi

  if [[ -z "$roster_channel" && -n "$access_channel" ]]; then
    warnings+=("Set BRIDGE_AGENT_DISCORD_CHANNEL_ID[\"$agent\"]=\"$access_channel\" in agent-roster.local.sh so wake relay can monitor the primary Discord channel.")
  fi
  if [[ -n "$roster_channel" && ${#access_channels[@]} -gt 0 ]]; then
    local access_match=0
    local channel_id=""
    for channel_id in "${access_channels[@]}"; do
      if [[ "$channel_id" == "$roster_channel" ]]; then
        access_match=1
        break
      fi
    done
    if [[ $access_match -eq 0 ]]; then
      warnings+=("Roster Discord channel $roster_channel is not in $(bridge_agent_discord_state_dir "$agent")/access.json. Re-run 'agent-bridge setup discord $agent' or update the allowlist.")
    fi
  fi
  if { bridge_channel_csv_contains "$required_channels" "plugin:telegram" \
      || bridge_channel_csv_contains "$required_channels" "plugin:telegram-relay"; } \
      && [[ ${#telegram_allow_from[@]} -eq 0 ]]; then
    warnings+=("Telegram role has no allow_from ids in $(bridge_agent_telegram_state_dir "$agent")/access.json. Re-run 'agent-bridge setup telegram $agent' and add intended users.")
  fi
  if bridge_channel_csv_contains "$required_channels" "plugin:teams" && [[ ${#teams_allow_from[@]} -eq 0 && ${#teams_conversations[@]} -eq 0 ]]; then
    warnings+=("Teams role has no allow_from ids or conversations in $(bridge_agent_teams_state_dir "$agent")/access.json. Re-run 'agent-bridge setup teams $agent' and add intended users or Teams conversations.")
  fi
  if [[ "$engine" == "claude" && "$wake_status" == "miss" ]]; then
    warnings+=("Claude role has no session metadata for idle wake. Verify BRIDGE_AGENT_SESSION is set and restart the session after deploy.")
  fi
  if [[ -n "$channel_reason" ]]; then
    warnings+=("Channel health check failed: $channel_reason")
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo
    echo "== Next steps =="
    printf -- '- %s\n' "${warnings[@]}"
  fi

  if (( failures > 0 )); then
    return 1
  fi
}

run_admin() {
  local agent="${1:-}"

  shift || true
  if [[ "$agent" == "-h" || "$agent" == "--help" || "$agent" == "help" ]]; then
    setup_subcommand_usage "admin"
    return 0
  fi
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") admin <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 setup admin 옵션입니다: $1"

  bridge_require_static_agent "$agent"

  echo "== Admin role =="
  printf 'admin_agent: %s\n' "$agent"
  printf 'engine: %s\n' "$(bridge_agent_engine "$agent")"
  printf 'workdir: %s\n' "$(bridge_agent_workdir "$agent")"
  bridge_setup_write_local_scalar "BRIDGE_ADMIN_AGENT_ID" "$agent"
  printf 'saved_in: %s\n' "$BRIDGE_ROSTER_LOCAL_FILE"
  echo "next_command: agb admin"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  discord)
    run_discord "$@"
    ;;
  telegram)
    run_telegram "$@"
    ;;
  teams)
    run_teams "$@"
    ;;
  agent)
    run_agent "$@"
    ;;
  admin)
    run_admin "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    # Issue #163 Phase 2: surface an intent-recovery hint before dying.
    _hint="$(bridge_suggest_subcommand "$subcommand" \
      "discord telegram teams agent admin")"
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 setup 명령입니다: $subcommand"
    ;;
esac
