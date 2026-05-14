#!/usr/bin/env bash
# bridge-init.sh — bootstrap a manager/admin role for a fresh Agent Bridge install

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Issue #665: the layout resolver fails fast on markerless installs. On a
# fresh install the marker does not yet exist, so we MUST arm the
# fresh-install bypass before sourcing bridge-lib.sh. The resolver only
# honors the bypass when classification is fresh-install-candidate
# (no existing-install evidence) — an existing markerless install still
# trips the v0.8.0 fail-fast and is sent to `agent-bridge upgrade --apply`.
# The bypass value carries a unique nonce, and the resolver only honors
# it when the calling process is a descendant of the init owner PID, so
# a leaked or copied env var alone cannot disarm the fail-fast guard.
_BRIDGE_INIT_BYPASS_NONCE="$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}${RANDOM}"
export BRIDGE_LAYOUT_RESOLVER_BYPASS="fresh-install:${_BRIDGE_INIT_BYPASS_NONCE}"
export BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID=$$
trap 'unset BRIDGE_LAYOUT_RESOLVER_BYPASS BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
# shellcheck source=lib/bridge-admin-pair.sh
source "$SCRIPT_DIR/lib/bridge-admin-pair.sh"
# shellcheck source=lib/bridge-host-profile.sh
source "$SCRIPT_DIR/lib/bridge-host-profile.sh"
# shellcheck source=lib/bridge-init-default-crons.sh
source "$SCRIPT_DIR/lib/bridge-init-default-crons.sh"
# bridge_load_roster is deferred until after argument parsing so that
# `init --dry-run` is mutation-free (bridge_load_roster -> bridge_init_dirs
# would otherwise create $BRIDGE_HOME/state on a fresh-install-candidate and
# turn the resolver classification into missing-marker(existing) on the next
# probe). Layout resolver has already run via bridge-lib.sh source.

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--admin <agent>] [--engine claude|codex] [--session <name>] [--workdir <path>] [--user <id[:display-name]>]... [--channels <csv>] [--discord-channel <id>]... [--allow-from <id>]... [--default-chat <id>] [--teams-app-id <id>] [--teams-app-password <secret>] [--teams-tenant-id <id>] [--teams-allow-from <id>]... [--teams-conversation <id>]... [--channel-account <account>] [--runtime-config <path>] [--api-base-url <url>] [--profile server|dev] [--reconfigure] [--skip-validate] [--skip-send-test] [--skip-channel-setup] [--test-start] [--dry-run] [--json]

Examples:
  $(basename "$0") --admin patch --engine claude --channels plugin:telegram@claude-plugins-official --allow-from 123456789 --default-chat 123456789 --channel-account default
  $(basename "$0") --admin manager --engine codex --dry-run --json
EOF
}

bridge_init_emit_json() {
  local admin="$1"
  local engine="$2"
  local session="$3"
  local workdir="$4"
  local channels="$5"
  local created="$6"
  local channel_setup="$7"
  local preflight="$8"
  local admin_saved="$9"
  local dry_run="${10}"
  local warnings_json="${11}"

  bridge_require_python
  python3 - "$admin" "$engine" "$session" "$workdir" "$channels" "$created" "$channel_setup" "$preflight" "$admin_saved" "$dry_run" "$warnings_json" <<'PY'
import json
import sys

admin, engine, session, workdir, channels, created, channel_setup, preflight, admin_saved, dry_run, warnings_json = sys.argv[1:]
payload = {
    "admin": admin,
    "engine": engine,
    "session": session,
    "workdir": workdir,
    "channels": channels,
    "created": created == "1",
    "channel_setup": channel_setup,
    "preflight": preflight,
    "admin_saved": admin_saved == "1",
    "dry_run": dry_run == "1",
    "warnings": json.loads(warnings_json),
    "next_command": "agb admin" if admin_saved == "1" else "",
    "handoff_steps": [
        "Close the temporary installer session.",
        "Open a fresh shell if needed so shell integration is loaded.",
        "Run `agb admin`.",
        "Let the admin role guide the rest of the onboarding.",
    ] if admin_saved == "1" else [],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

bridge_init_require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || bridge_die "필수 명령을 찾지 못했습니다: $cmd"
}

bridge_init_runtime_present() {
  local kind="$1"
  local agent="$2"

  case "$kind" in
    discord)
      [[ -f "$(bridge_agent_discord_state_dir "$agent")/.env" && -f "$(bridge_agent_discord_state_dir "$agent")/access.json" ]]
      ;;
    telegram)
      [[ -f "$(bridge_agent_telegram_state_dir "$agent")/.env" && -f "$(bridge_agent_telegram_state_dir "$agent")/access.json" ]]
      ;;
    teams)
      [[ -f "$(bridge_agent_teams_state_dir "$agent")/.env" && -f "$(bridge_agent_teams_state_dir "$agent")/access.json" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_init_append_warning() {
  local message="$1"
  WARNINGS+=("$message")
}

bridge_init_run_step() {
  local label="$1"
  shift
  local output=""

  if ! output="$("$@" 2>&1)"; then
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    bridge_die "$label failed"
  fi
}

bridge_init_ensure_live_cli() {
  # Issue #4282 Wave-5: on a non-dry-run init, deploy the live CLI under
  # $BRIDGE_HOME so the operator's next command (`~/.agent-bridge/agent-bridge
  # agent create ...`, the canonical post-init flow documented in the
  # OrbStack VM E2E retest brief) finds the binary it expects. Without
  # this, `bridge-init.sh` from a fresh source checkout returned rc=0 with
  # only state/runtime/shared/ scaffolded — the `agent-bridge` script
  # itself stayed under $SCRIPT_DIR (which is $HOME/.agent-bridge-source,
  # not $BRIDGE_HOME), and operators / VM retest harnesses fell off the
  # documented path with `~/.agent-bridge/agent-bridge: No such file or
  # directory`. The only existing code that materializes the CLI under
  # $BRIDGE_HOME was the standalone `scripts/deploy-live-install.sh` —
  # tracked in OPERATIONS.md as the upgrade path, never wired into the
  # fresh-init dispatch. Wire it here so `agent-bridge init` is the single
  # post-clone entry point operators need.
  #
  # Idempotent: short-circuits when the CLI already exists at the live
  # path (re-init / partial-state recovery) and when init was invoked
  # from $BRIDGE_HOME directly (self-deploy would overwrite live state
  # we are still initializing). Errors fail-fast through
  # `bridge_init_run_step` rather than warn-and-continue, since a
  # missing live CLI breaks the whole operator workflow.
  [[ $dry_run -eq 0 ]] || return 0
  [[ -x "$BRIDGE_HOME/agent-bridge" ]] && return 0
  local script_dir_canonical bridge_home_canonical
  script_dir_canonical="$(cd -P "$SCRIPT_DIR" 2>/dev/null && pwd -P || printf '%s' "$SCRIPT_DIR")"
  bridge_home_canonical="$(cd -P "$BRIDGE_HOME" 2>/dev/null && pwd -P || printf '%s' "$BRIDGE_HOME")"
  [[ "$script_dir_canonical" != "$bridge_home_canonical" ]] || return 0
  bridge_init_run_step "live install deploy" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/deploy-live-install.sh" --target "$BRIDGE_HOME"
}

bridge_init_warnings_json() {
  bridge_require_python
  python3 - "${WARNINGS[@]}" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:], ensure_ascii=False))
PY
}

admin_agent="${BRIDGE_ADMIN_AGENT_ID:-admin}"
engine="claude"
session=""
workdir=""
profile_home=""
display_name=""
role_text="Manager/admin role"
description=""
channels=""
channel_account=""
runtime_config="$HOME/.agent-bridge/runtime/bridge-config.json"
data_root_flag=""
skip_channel_setup=0
test_start=0
dry_run=0
json_mode=0
always_on=1
skip_validate=0
skip_send_test=0
channel_setup_status="skipped"
preflight_status="skipped"
admin_saved=0
created=0
WARNINGS=()
discord_channels=()
telegram_allow_from=()
default_chat=""
teams_app_id=""
teams_app_password=""
teams_tenant_id=""
teams_service_url=""
teams_allow_from=()
teams_conversations=()
notify_kind=""
notify_target=""
notify_account=""
api_base_url=""
user_specs=()
host_profile_reconfigure=0
host_profile_override=""
host_profile_chosen=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      admin_agent="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      engine="$2"
      shift 2
      ;;
    --session)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      session="$2"
      shift 2
      ;;
    --workdir)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      workdir="$2"
      shift 2
      ;;
    --profile-home)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      profile_home="$2"
      shift 2
      ;;
    --display-name)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      display_name="$2"
      shift 2
      ;;
    --role)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      role_text="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      description="$2"
      shift 2
      ;;
    --channels)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      channels="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      user_specs+=("$2")
      shift 2
      ;;
    --discord-channel)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      discord_channels+=("$2")
      shift 2
      ;;
    --allow-from)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      telegram_allow_from+=("$2")
      shift 2
      ;;
    --default-chat)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      default_chat="$2"
      shift 2
      ;;
    --teams-app-id)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_app_id="$2"
      shift 2
      ;;
    --teams-app-password)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_app_password="$2"
      shift 2
      ;;
    --teams-tenant-id)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_tenant_id="$2"
      shift 2
      ;;
    --teams-service-url)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_service_url="$2"
      shift 2
      ;;
    --teams-allow-from)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_allow_from+=("$2")
      shift 2
      ;;
    --teams-conversation)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_conversations+=("$2")
      shift 2
      ;;
    --channel-account|--openclaw-account)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      channel_account="$2"
      shift 2
      ;;
    --runtime-config|--openclaw-config)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      runtime_config="$2"
      shift 2
      ;;
    --data-root)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      data_root_flag="$2"
      shift 2
      ;;
    --api-base-url)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      api_base_url="$2"
      shift 2
      ;;
    --notify-kind)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      notify_kind="$2"
      shift 2
      ;;
    --notify-target)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      notify_target="$2"
      shift 2
      ;;
    --notify-account)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      notify_account="$2"
      shift 2
      ;;
    --skip-channel-setup)
      skip_channel_setup=1
      shift
      ;;
    --skip-validate)
      skip_validate=1
      shift
      ;;
    --skip-send-test)
      skip_send_test=1
      shift
      ;;
    --test-start)
      test_start=1
      shift
      ;;
    --always-on)
      always_on=1
      shift
      ;;
    --reconfigure)
      host_profile_reconfigure=1
      shift
      ;;
    --profile)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      case "$2" in
        server|dev) host_profile_override="$2" ;;
        *) bridge_die "--profile 은 server 또는 dev 여야 합니다 (got: $2)" ;;
      esac
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --json)
      json_mode=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      bridge_die "지원하지 않는 init 옵션입니다: $1"
      ;;
  esac
done

case "$engine" in
  claude|codex) ;;
  *) bridge_die "지원하지 않는 engine 입니다: $engine" ;;
esac

# Layout resolution + (fresh install only) marker write. This must run before
# bridge_load_roster — once the roster is loaded, bridge_init_dirs has
# materialized $BRIDGE_HOME/state and the v2 layout choice has to be honored
# by every subsequent call site (workdir, env writer, etc.).
init_layout_planned=""
# Issue #418 codex r1 #4: marker write also fires when the operator
# explicitly sets `BRIDGE_LAYOUT=v2` in env before running init. Without
# this, env-set v2 init runs v2 transiently but no durable marker is
# written, so when env unsets later the install reverts to legacy on the
# same data. The legacy env path stays no-op because legacy is the
# default and doesn't need a marker.
_init_should_write_marker=0
case "${BRIDGE_LAYOUT_SOURCE:-}" in
  fresh-install-candidate)
    _init_should_write_marker=1
    ;;
  env)
    if [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]]; then
      _init_should_write_marker=1
    fi
    ;;
esac
if [[ $_init_should_write_marker -eq 1 ]]; then
  fresh_data_root="${data_root_flag:-${BRIDGE_DATA_ROOT:-${BRIDGE_DEFAULT_DATA_ROOT:-$BRIDGE_HOME/data}}}"
  if [[ "${fresh_data_root:0:1}" != "/" ]]; then
    bridge_die "--data-root must be absolute (got '$fresh_data_root')"
  fi
  init_layout_planned="layout=v2 source=fresh-install data_root=$fresh_data_root"
  if [[ $dry_run -eq 0 ]]; then
    bridge_layout_write_v2_marker "$fresh_data_root"
    # Re-resolve from scratch so BRIDGE_LAYOUT_SOURCE is attributable to the
    # marker we just wrote (not forced to "marker" on faith). Resetting the
    # source first ensures bridge_resolve_layout takes the marker branch
    # rather than re-running env validation against a stale snapshot.
    #
    # Critical: bridge-isolation-v2.sh's `BRIDGE_LAYOUT="${BRIDGE_LAYOUT:-legacy}"`
    # default fired during the initial bridge-lib.sh source. If we leave
    # BRIDGE_LAYOUT=legacy in the environment now, the resolver's env-validate
    # step would treat that as a valid explicit override and return
    # source=env instead of source=marker. Unset both v2 anchor vars so the
    # resolver only sees the marker we just wrote.
    BRIDGE_LAYOUT_SOURCE=""
    unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
    bridge_resolve_layout
    if [[ "${BRIDGE_LAYOUT_SOURCE:-}" != "marker" ]]; then
      # The marker we just wrote is poison. Unlink it so the next init
      # invocation starts from a clean fresh-install-candidate state
      # rather than tripping over a stale half-init artifact.
      _marker_path="$(bridge_isolation_v2_marker_path)"
      [[ -f "$_marker_path" ]] && rm -f "$_marker_path"
      bridge_die "init: marker write succeeded but resolver did not re-load it (got source=${BRIDGE_LAYOUT_SOURCE:-unknown}). Marker removed — please retry."
    fi
    if [[ -n "${BRIDGE_DATA_ROOT:-}" ]]; then
      BRIDGE_SHARED_ROOT="${BRIDGE_SHARED_ROOT:-$BRIDGE_DATA_ROOT/shared}"
      BRIDGE_AGENT_ROOT_V2="${BRIDGE_AGENT_ROOT_V2:-$BRIDGE_DATA_ROOT/agents}"
      BRIDGE_CONTROLLER_STATE_ROOT="${BRIDGE_CONTROLLER_STATE_ROOT:-$BRIDGE_DATA_ROOT/state}"
      export BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
    fi
  fi
elif [[ -n "$data_root_flag" ]]; then
  bridge_die "--data-root only applies on fresh installs (current layout source=${BRIDGE_LAYOUT_SOURCE:-unknown}). Use \`agent-bridge migrate isolation-v2\` to relocate an existing install."
fi

# Now safe to load the roster. bridge_init_dirs will materialize either the
# legacy $BRIDGE_HOME/state tree or the v2 tree depending on the marker we
# just wrote (or didn't). Skipped on --dry-run to honor the mutation-free
# contract: bridge_init_dirs creates state/, runtime/, shared/, cron/, etc.
# and would otherwise leave artifacts behind on a probe.
if [[ $dry_run -eq 0 ]]; then
  bridge_load_roster
fi

session="${session:-$admin_agent}"
description="${description:-$admin_agent admin role}"
display_name="${display_name:-$admin_agent}"
channels="$(bridge_normalize_channels_csv "$channels")"

bridge_init_require_command tmux
bridge_init_require_command python3
bridge_init_require_command "$engine"

if [[ $dry_run -eq 1 ]]; then
  # Dry-run mutation-free contract: do not invoke `agent create` as a
  # sub-process — its bridge-lib.sh source would call bridge_load_roster
  # via the dispatcher and materialize $BRIDGE_HOME/{state,runtime,...}.
  # The plan output downstream uses the user-supplied values directly.
  created=1
elif bridge_agent_exists "$admin_agent"; then
  bridge_require_static_agent "$admin_agent"
else
  create_args=(agent create "$admin_agent" --engine "$engine" --session-type admin --session "$session" --display-name "$display_name" --role "$role_text" --description "$description")
  [[ -n "$workdir" ]] && create_args+=(--workdir "$workdir")
  [[ -n "$profile_home" ]] && create_args+=(--profile-home "$profile_home")
  [[ -n "$channels" ]] && create_args+=(--channels "$channels")
  for item in "${user_specs[@]}"; do
    create_args+=(--user "$item")
  done
  [[ -n "$notify_kind" ]] && create_args+=(--notify-kind "$notify_kind")
  [[ -n "$notify_target" ]] && create_args+=(--notify-target "$notify_target")
  [[ -n "$notify_account" ]] && create_args+=(--notify-account "$notify_account")
  if [[ $always_on -eq 1 ]]; then
    create_args+=(--always-on)
  fi
  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" "${create_args[@]}" >/dev/null
  created=1
  bridge_load_roster
fi

# Issue #517: ensure the admin's sibling codex dev pair (`<admin>-dev`) and
# inject the pair-programming SOP managed block into the admin's CLAUDE.md.
# Applies regardless of admin engine — the pair is always engine=codex; the
# SOP block is engine-neutral (it talks about plan/review/implement loops,
# which apply to any orchestrator). Tolerant on failure — pair backfill must
# never fail an otherwise-successful admin install. Skipped on --dry-run to
# honor the mutation-free contract.
if [[ $dry_run -eq 0 ]]; then
  pair_output=""
  if ! pair_output="$(bridge_ensure_admin_codex_pair "$admin_agent" 2>&1)"; then
    bridge_init_append_warning "admin-pair backfill failed: ${pair_output}"
  else
    [[ -n "$pair_output" ]] && printf '%s\n' "$pair_output" >&2
    bridge_load_roster
    inject_output=""
    if ! inject_output="$(python3 "$SCRIPT_DIR/bridge-upgrade.py" inject-admin-pair-block --target-root "$BRIDGE_HOME" --admin-agent "$admin_agent" 2>&1)"; then
      bridge_init_append_warning "admin-pair CLAUDE.md inject failed: ${inject_output}"
    fi
  fi
fi

if [[ $dry_run -eq 0 ]] && [[ "$(bridge_agent_engine "$admin_agent" 2>/dev/null || printf '%s' "$engine")" == "claude" ]]; then
  admin_workdir="$(bridge_agent_workdir "$admin_agent" 2>/dev/null || true)"
  if [[ -n "$admin_workdir" ]]; then
    admin_launch_cmd="$(bridge_agent_launch_cmd_raw "$admin_agent" 2>/dev/null || true)"
    # Issue #555: pass admin agent id so the rendered effective file
    # lives at $BRIDGE_AGENT_HOME_ROOT/<admin>/.claude/settings.effective.json
    # (per-agent), not the install-wide path that would later be overwritten
    # by other managed agents' rerenders.
    bridge_ensure_claude_shared_settings_for_managed_workdir "$admin_workdir" "$admin_launch_cmd" "$admin_agent" >/dev/null 2>&1 || true
  fi
fi

# Issue #713 follow-up: ask the operator whether this is a server (always-on
# production host) or a developer PC, then let the dev branch short-circuit the
# heavy server-only setup that follows. Must run AFTER the admin agent and its
# codex pair exist (the dev advisory references them by id) but BEFORE channel
# bootstrap so a `dev` answer skips Discord/Telegram/Teams/Mattermost setup
# entirely instead of forcing the operator to confirm or `--skip-channel-setup`
# every flag. Re-running init on an already-answered host is idempotent unless
# `--reconfigure` is passed; non-interactive (`--json`, no TTY) defaults to
# `server` to preserve today's behavior on hosted installs. Skipped on
# `--dry-run` (mutation-free contract).
if [[ $dry_run -eq 0 ]]; then
  bridge_init_ensure_live_cli
  # Prefer the live CLI deployed under $BRIDGE_HOME (canonical post-init
  # surface — bridge_init_ensure_live_cli just materialized it). Fall back
  # to the source checkout's CLI when init is invoked from $BRIDGE_HOME
  # itself (the self-deploy short-circuit branch).
  host_profile_cli="$BRIDGE_HOME/agent-bridge"
  if [[ ! -x "$host_profile_cli" ]]; then
    host_profile_cli="$SCRIPT_DIR/agent-bridge"
  fi
  host_profile_chosen="$(bridge_host_profile_run \
    "$host_profile_cli" \
    "$host_profile_reconfigure" \
    "$host_profile_override" \
    "$json_mode" \
    "$admin_agent")" || host_profile_chosen=""
  if [[ "$host_profile_chosen" == "dev" ]] && [[ $skip_channel_setup -eq 0 ]]; then
    skip_channel_setup=1
    if [[ -n "$channels" ]]; then
      bridge_init_append_warning "host_profile=dev: requested channels (${channels}) — channel bootstrap skipped this init. Re-run \`agb setup <channel> ${admin_agent}\` later or pass \`--profile server\` to enable on this install."
    fi
  fi
  # Track D follow-up to #713 / #809, follow-on to #833: auto-register the
  # picker-sweep bridge-native cron on every fresh install, regardless of
  # host_profile. The helper is idempotent (short-circuits when a job titled
  # `picker-sweep` already exists), and the registered cron payload sets
  # `BRIDGE_PICKER_SWEEP_ENABLED=1` — that env var wins against the runtime
  # host_profile=dev default-skip in scripts/picker-sweep.sh, so a dev install
  # gets a working sweep without an extra opt-in step. Operators who want the
  # sweep disabled can `agb cron update picker-sweep --disable` after init.
  # Non-fatal: helper logs and returns 0 on any failure so init keeps going.
  if [[ -n "$host_profile_chosen" ]]; then
    bridge_init_register_default_picker_sweep "$host_profile_cli" "$admin_agent" || true
  fi
fi

if [[ $skip_channel_setup -eq 0 ]] && [[ $dry_run -eq 0 ]]; then
  channel_setup_status="ok"
  if bridge_channel_csv_contains "$channels" "plugin:discord"; then
    if ((${#discord_channels[@]} > 0)) || [[ -n "$channel_account" ]] || bridge_init_runtime_present discord "$admin_agent"; then
      setup_args=(discord "$admin_agent")
      for item in "${discord_channels[@]}"; do
        setup_args+=(--channel "$item")
      done
      [[ -n "$channel_account" ]] && setup_args+=(--channel-account "$channel_account")
      [[ -n "$runtime_config" ]] && setup_args+=(--runtime-config "$runtime_config")
      [[ -n "$api_base_url" ]] && setup_args+=(--api-base-url "$api_base_url")
      [[ $skip_validate -eq 1 ]] && setup_args+=(--skip-validate)
      [[ $skip_send_test -eq 1 ]] && setup_args+=(--skip-send-test)
      setup_args+=(--yes)
      bridge_init_run_step "discord bootstrap" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${setup_args[@]}"
    else
      channel_setup_status="partial"
      bridge_init_append_warning "Discord channel setup skipped: no existing runtime, channel ids, or --channel-account provided."
    fi
  fi
  if bridge_channel_csv_contains "$channels" "plugin:telegram"; then
    if ((${#telegram_allow_from[@]} > 0)) || [[ -n "$channel_account" ]] || bridge_init_runtime_present telegram "$admin_agent"; then
      setup_args=(telegram "$admin_agent")
      for item in "${telegram_allow_from[@]}"; do
        setup_args+=(--allow-from "$item")
      done
      [[ -n "$default_chat" ]] && setup_args+=(--default-chat "$default_chat")
      [[ -n "$channel_account" ]] && setup_args+=(--channel-account "$channel_account")
      [[ -n "$runtime_config" ]] && setup_args+=(--runtime-config "$runtime_config")
      [[ -n "$api_base_url" ]] && setup_args+=(--api-base-url "$api_base_url")
      [[ $skip_validate -eq 1 ]] && setup_args+=(--skip-validate)
      [[ $skip_send_test -eq 1 ]] && setup_args+=(--skip-send-test)
      setup_args+=(--yes)
      bridge_init_run_step "telegram bootstrap" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${setup_args[@]}"
    else
      channel_setup_status="partial"
      bridge_init_append_warning "Telegram channel setup skipped: no existing runtime, allow_from ids, or --channel-account provided."
    fi
  fi
  if bridge_channel_csv_contains "$channels" "plugin:teams"; then
    if ((${#teams_allow_from[@]} > 0)) || ((${#teams_conversations[@]} > 0)) || [[ -n "$channel_account" ]] || [[ -n "$teams_app_id" && -n "$teams_app_password" ]] || bridge_init_runtime_present teams "$admin_agent"; then
      setup_args=(teams "$admin_agent")
      for item in "${teams_allow_from[@]}"; do
        setup_args+=(--allow-from "$item")
      done
      for item in "${teams_conversations[@]}"; do
        setup_args+=(--conversation "$item")
      done
      [[ -n "$teams_app_id" ]] && setup_args+=(--app-id "$teams_app_id")
      [[ -n "$teams_app_password" ]] && setup_args+=(--app-password "$teams_app_password")
      [[ -n "$teams_tenant_id" ]] && setup_args+=(--tenant-id "$teams_tenant_id")
      [[ -n "$teams_service_url" ]] && setup_args+=(--service-url "$teams_service_url")
      [[ -n "$channel_account" ]] && setup_args+=(--channel-account "$channel_account")
      [[ -n "$runtime_config" ]] && setup_args+=(--runtime-config "$runtime_config")
      [[ $skip_validate -eq 1 ]] && setup_args+=(--skip-validate)
      [[ $skip_send_test -eq 1 ]] && setup_args+=(--skip-send-test)
      setup_args+=(--yes)
      bridge_init_run_step "teams bootstrap" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${setup_args[@]}"
    else
      channel_setup_status="partial"
      bridge_init_append_warning "Teams channel setup skipped: no existing runtime, teams credentials, allow_from ids, conversations, or --channel-account provided."
    fi
  fi
fi

if [[ $dry_run -eq 0 ]]; then
  preflight_args=(agent "$admin_agent" --skip-discord --skip-telegram --skip-teams)
  if [[ $test_start -eq 1 ]]; then
    preflight_args+=(--test-start)
  fi
  bridge_init_run_step "agent preflight" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${preflight_args[@]}"
  preflight_status="ok"
  bridge_init_run_step "admin handoff save" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" admin "$admin_agent"
  admin_saved=1
else
  preflight_status="dry-run"
fi

if [[ $dry_run -eq 1 ]]; then
  # Dry-run path skipped bridge_load_roster, so the BRIDGE_AGENT_* arrays
  # are not declared. Use the user-supplied values directly for the plan.
  final_engine="$engine"
  final_session="$session"
  final_workdir="${workdir:-$BRIDGE_HOME/agents/$admin_agent}"
else
  final_engine="${BRIDGE_AGENT_ENGINE[$admin_agent]-$engine}"
  final_session="${BRIDGE_AGENT_SESSION[$admin_agent]-$session}"
  final_workdir="${BRIDGE_AGENT_WORKDIR[$admin_agent]-${workdir:-$(bridge_agent_default_home "$admin_agent")}}"
fi

bridge_init_ensure_live_cli

# Note: host_profile_run (Issue #713) was called earlier — before channel
# bootstrap — so a `dev` answer can short-circuit the Discord/Telegram/Teams/
# Mattermost setup steps. host_profile_chosen is already populated by that
# call (or empty on --dry-run).

warnings_json="$(bridge_init_warnings_json)"

if [[ $json_mode -eq 1 ]]; then
  bridge_init_emit_json \
    "$admin_agent" \
    "$final_engine" \
    "$final_session" \
    "$final_workdir" \
    "$channels" \
    "$created" \
    "$channel_setup_status" \
    "$preflight_status" \
    "$admin_saved" \
    "$dry_run" \
    "$warnings_json"
  exit 0
fi

echo "== Bridge init =="
if [[ -n "$init_layout_planned" ]]; then
  if [[ $dry_run -eq 1 ]]; then
    printf 'layout_plan: %s (dry-run, marker not written)\n' "$init_layout_planned"
  else
    printf 'layout_plan: %s (marker written)\n' "$init_layout_planned"
  fi
fi
printf 'layout: %s\n' "$(bridge_layout_status_summary)"
printf 'admin_agent: %s\n' "$admin_agent"
printf 'engine: %s\n' "$final_engine"
printf 'session: %s\n' "$final_session"
printf 'workdir: %s\n' "$final_workdir"
printf 'channels: %s\n' "${channels:-"(none)"}"
printf 'created: %s\n' "$([[ $created -eq 1 ]] && echo yes || echo no)"
printf 'channel_setup: %s\n' "$channel_setup_status"
printf 'preflight: %s\n' "$preflight_status"
printf 'admin_saved: %s\n' "$([[ $admin_saved -eq 1 ]] && echo yes || echo no)"
if [[ -n "$host_profile_chosen" ]]; then
  printf 'host_profile: %s\n' "$host_profile_chosen"
fi
for warning in "${WARNINGS[@]}"; do
  printf 'warning: %s\n' "$warning"
done
if [[ $admin_saved -eq 1 ]]; then
  echo "next_command: agb admin"
  echo "handoff:"
  echo "1. Close the temporary installer session."
  echo "2. Open a fresh shell if this terminal has not reloaded your shell rc yet."
  echo "3. Run: agb admin"
  echo "4. Let the admin role guide the rest of the onboarding."
fi
