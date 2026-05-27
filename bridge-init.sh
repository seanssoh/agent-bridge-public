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
# A staged channel-secret temp file (see bridge_init_stage_secret); removed on
# exit so a legacy --teams-app-password value never outlives this process.
_BRIDGE_INIT_SECRET_TMPFILE=""
trap 'unset BRIDGE_LAYOUT_RESOLVER_BYPASS BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID; [[ -n "${_BRIDGE_INIT_SECRET_TMPFILE:-}" ]] && rm -f "$_BRIDGE_INIT_SECRET_TMPFILE"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
# shellcheck source=lib/bridge-host-profile.sh
source "$SCRIPT_DIR/lib/bridge-host-profile.sh"
# shellcheck source=lib/bridge-init-default-crons.sh
source "$SCRIPT_DIR/lib/bridge-init-default-crons.sh"
# shellcheck source=lib/bridge-init-codex-pair.sh
source "$SCRIPT_DIR/lib/bridge-init-codex-pair.sh"
# bridge_load_roster is deferred until after argument parsing so that
# `init --dry-run` is mutation-free (bridge_load_roster -> bridge_init_dirs
# would otherwise create $BRIDGE_HOME/state on a fresh-install-candidate and
# turn the resolver classification into missing-marker(existing) on the next
# probe). Layout resolver has already run via bridge-lib.sh source.

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--admin <agent>] [--engine claude|codex] [--session <name>] [--workdir <path>] [--user <id[:display-name]>]... [--channels <csv>] [--discord-channel <id>]... [--allow-from <id>]... [--default-chat <id>] [--teams-app-id <id>] [--teams-app-password-file <path>] [--teams-tenant-id <id>] [--teams-allow-from <id>]... [--teams-conversation <id>]... [--channel-account <account>] [--runtime-config <path>] [--api-base-url <url>] [--profile server|dev] [--reconfigure] [--skip-validate] [--skip-send-test] [--skip-channel-setup] [--test-start] [--dry-run] [--json]

  The Teams client secret may also be supplied via the BRIDGE_TEAMS_APP_PASSWORD
  environment variable. --teams-app-password <secret> is still accepted but
  deprecated: it exposes the secret in shell history and process argv.

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

bridge_init_stage_secret() {
  # Stage a secret value into a private (mode 600) temp file so it can be
  # forwarded downstream by path — a path is safe in argv, the secret is not.
  # Assigns _BRIDGE_INIT_SECRET_TMPFILE immediately after mktemp — before the
  # chmod/write steps — so the EXIT trap can still remove the file if a later
  # step fails. MUST NOT be called in a command substitution: it sets a global
  # (a subshell assignment would not survive). Only one staged secret per run.
  local value="$1"
  local tmpfile
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/bridge-init-secret.XXXXXX")" \
    || bridge_die "비밀 값을 임시 파일로 옮기지 못했습니다"
  _BRIDGE_INIT_SECRET_TMPFILE="$tmpfile"
  chmod 600 "$tmpfile"
  printf '%s' "$value" >"$tmpfile"
}

bridge_init_runtime_present() {
  # beta23 Option A: route the controller-blind probe through
  # bridge_iso_run --op stat. The legacy `[[ -f path ]]` direct test
  # would false-negative on an isolated workdir the controller cannot
  # stat (#1165 Gap 5 family). The helper transparently falls back
  # to direct stat on non-isolated agents (rc=0 vs rc=30).
  local kind="$1"
  local agent="$2"
  local dir=""

  case "$kind" in
    discord)  dir="$(bridge_agent_discord_state_dir "$agent")"  ;;
    telegram) dir="$(bridge_agent_telegram_state_dir "$agent")" ;;
    teams)    dir="$(bridge_agent_teams_state_dir "$agent")"    ;;
    *)        return 1 ;;
  esac
  [[ -n "$dir" ]] || return 1

  if declare -F bridge_iso_run >/dev/null 2>&1; then
    bridge_iso_run --agent "$agent" --op stat --path "$dir/.env" \
      --test file >/dev/null 2>&1 || return 1
    bridge_iso_run --agent "$agent" --op stat --path "$dir/access.json" \
      --test file >/dev/null 2>&1 || return 1
    return 0
  fi

  # Legacy fallback when bridge_iso_run is not loaded yet (very early
  # init paths before bridge-lib has sourced the helper).
  [[ -f "$dir/.env" && -f "$dir/access.json" ]]
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

admin_agent="${BRIDGE_ADMIN_AGENT_ID:-patch}"
engine="claude"
session=""
workdir=""
profile_home=""
display_name=""
role_text="Manager/admin role"
description=""
channels=""
channel_account=""
# Default to the canonical runtime config path resolved by bridge-lib.sh
# (rooted at $BRIDGE_HOME), not the operator's $HOME — a custom BRIDGE_HOME
# install must not read/write channel config under the default ~/.agent-bridge.
runtime_config="$BRIDGE_RUNTIME_CONFIG_FILE"
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
teams_app_password_file=""
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
      bridge_warn "--teams-app-password는 셸 히스토리와 프로세스 argv에 client secret을 노출합니다. --teams-app-password-file <path> 또는 BRIDGE_TEAMS_APP_PASSWORD 환경변수를 사용하세요."
      # Stage the secret out of argv immediately so it is never re-exposed
      # in the bridge-setup.sh / bridge-setup.py argv downstream. A repeated
      # flag replaces the prior staged file so no orphan outlives the trap,
      # which only tracks the most recent _BRIDGE_INIT_SECRET_TMPFILE.
      # bridge_init_stage_secret sets _BRIDGE_INIT_SECRET_TMPFILE directly
      # (not via $() — see its comment) so the trap sees the path even if a
      # later staging step fails.
      [[ -n "$_BRIDGE_INIT_SECRET_TMPFILE" ]] && rm -f "$_BRIDGE_INIT_SECRET_TMPFILE"
      bridge_init_stage_secret "$2"
      teams_app_password_file="$_BRIDGE_INIT_SECRET_TMPFILE"
      shift 2
      ;;
    --teams-app-password-file)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      teams_app_password_file="$2"
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
# v0.15.0-beta1 Lane I: replace the terse "<name> admin role" default with a
# concrete role description so downstream agents reading the roster on a fresh
# install see a useful sentence (issue: cosmax-* installs landed empty/terse
# desc → downstream agent autonomy regressed). The example roster
# (agent-roster.local.example.sh) carries the same boilerplate so operators
# can lift it verbatim. See docs/agent-runtime/admin-agent-convention.md.
description="${description:-Agent Bridge admin/coordinator for this install. Owns onboarding, roster/queue triage, upgrade/release waves, and operator-facing decisions.}"
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
  # Issue #1047: `agent create` is now caller-trust gated and rejects an
  # `agent-direct` source. This fresh-install admin create is an
  # operator-initiated bootstrap step, but it runs as a subprocess with a
  # redirected stdout so TTY detection would demote it to `agent-direct`.
  # Mark it as a sanctioned operator-trusted caller so the gate allows it.
  BRIDGE_CALLER_SOURCE="operator-trusted-id" \
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" "${create_args[@]}" >/dev/null
  created=1
  # Issue #848: the child `agent create` invocation mutated the roster
  # files on disk, so the next `bridge_load_roster` MUST re-parse them
  # rather than serve cached state from the earlier load above.
  bridge_roster_cache_invalidate
  bridge_load_roster
fi

# Issue #1052 (reconsiders #4769, which reverted #517): the `<admin>-dev`
# codex pair IS auto-provisioned on a fresh install — but only when the codex
# CLI is present AND the resolved host profile is `server`. That gated
# provisioning happens below, after host-profile resolution and before the
# picker-sweep cron registration (whose target is `<admin>-dev`). On a `dev`
# profile the install stays admin-only and the dev advisory prints the manual
# `agent create <admin>-dev --engine codex …` recipe; when codex is absent the
# claude admin runs solo.

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
# heavy server-only setup that follows. Must run AFTER the admin agent exists
# (the dev advisory references the admin and the `<admin>-dev` pair by id only
# — it does not require the pair to exist; issue #1052 provisions the codex
# pair LATER, just below, gated on the host_profile this step resolves) but
# BEFORE channel bootstrap so a `dev` answer skips Discord/Telegram/Teams/
# Mattermost setup entirely instead of forcing the operator to confirm or
# `--skip-channel-setup` every flag. Re-running init on an already-answered
# host is idempotent unless `--reconfigure` is passed; non-interactive
# (`--json`, no TTY) defaults to `server` to preserve today's behavior on
# hosted installs. Skipped on `--dry-run` (mutation-free contract).
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
  # Issue #1052: auto-provision the admin's `<admin>-dev` codex pair before
  # the picker-sweep cron registration below — the cron targets `<admin>-dev`,
  # so the pair must exist first or the registration skips. The helper is
  # gated on codex-CLI presence AND host_profile == server (the `dev` path
  # stays admin-only and keeps its manual-create advisory), and is idempotent
  # + non-fatal — re-running init when the pair already exists is a no-op and
  # any failure is logged without blocking init.
  bridge_init_provision_admin_codex_pair "$host_profile_cli" "$admin_agent" "$host_profile_chosen" || true

  # Issue #1231: idempotent bundled-marketplace seed for the v2 shared
  # plugin catalog. Without this, `agb agent create --isolate --channels
  # plugin:teams,plugin:ms365` on a fresh install bridge_die's with
  # "isolation v2 plugin catalog: \$BRIDGE_SHARED_ROOT/plugins-cache is
  # not populated" because Claude never wrote installed_plugins.json
  # there. `bridge-plugins.sh seed` is the de-facto post-fresh-install
  # step; we make it part of init so the operator does not have to know
  # about it.
  #
  # Contract:
  #   * Idempotent — re-running over a populated catalog is a no-op
  #     (the sync helper short-circuits when manifest entries already
  #     match the marketplace.json declarations).
  #   * Non-fatal on failure — init proceeds with a warning; the
  #     agent-create fallback in lib/bridge-agents.sh
  #     (bridge_linux_share_plugin_catalog) takes over as the
  #     fail-closed second chance.
  #   * Gated on v2 active — legacy installs do not have a shared
  #     plugin catalog contract.
  #   * Gated on the live CLI being present at $BRIDGE_HOME/agent-bridge
  #     (bridge_init_ensure_live_cli ran above); we use the live CLI so
  #     the seed runs against the operator-facing surface, not the
  #     source checkout (in case those paths diverge).
  if command -v bridge_isolation_v2_active >/dev/null 2>&1 \
     && bridge_isolation_v2_active 2>/dev/null \
     && [[ -x "$host_profile_cli" ]]; then
    _init_seed_output=""
    _init_seed_rc=0
    _init_seed_output="$("$BRIDGE_BASH_BIN" "$host_profile_cli" plugins seed 2>&1)" \
      || _init_seed_rc=$?
    if (( _init_seed_rc == 0 )); then
      # #1230 (v0.15.0-beta4): logger output goes to stderr so the
      # `--json` mode contract (stdout = data only) holds end-to-end.
      # Matches the #1273 convention applied to `bridge_info` in
      # lib/bridge-core.sh — log lines are diagnostics, not return-channel
      # producers. `bridge-bootstrap.sh` captures stdout via `$()` and
      # parses it as JSON; any log line on stdout poisons the parse.
      printf '[init] plugins seed: shared catalog populated (bundled agent-bridge marketplace)\n' >&2
    else
      [[ -n "$_init_seed_output" ]] && printf '%s\n' "$_init_seed_output" >&2
      bridge_init_append_warning "plugins seed failed (rc=$_init_seed_rc) — \$BRIDGE_SHARED_ROOT/plugins-cache may be empty. Re-run: agent-bridge plugins seed. \`agent create --isolate --channels plugin:*\` will attempt to self-heal via fallback seed; if that also fails, the create call will surface an actionable error."
    fi
  fi

  # Beta20 L2 Variant 3A — install the daemon-refresh sudoers drop-in on
  # Linux server hosts so subsequent `agent create --linux-user` calls
  # can automatically refresh the daemon's supplementary groups. The
  # helper no-ops on macOS (skipped-non-linux), on dev hosts (operators
  # who manage their own daemons), and on systems lacking visudo. Failure
  # is logged but does NOT block init — the operator can re-run
  # `agent-bridge init sudoers daemon-refresh --apply` later (or live
  # with the queue-only-fallback footgun until they do).
  if [[ "$host_profile_chosen" == "server" ]] \
     && [[ "$(uname -s 2>/dev/null)" == "Linux" ]] \
     && [[ $dry_run -eq 0 ]] \
     && command -v bridge_daemon_control_install_sudoers >/dev/null 2>&1; then
    # Issue #1236: gate the "installed: <path>" success line on the
    # verifier (`bridge_daemon_control_check_sudoers` via
    # `bridge_daemon_control_preflight_row`) actually accepting the
    # rendered drop-in. Previously the installer wrote the file and we
    # printed "installed at <path>" unconditionally, then the very next
    # line emitted `daemon_group_refresh_sudoers=missing|invalid|...`
    # when sudo/PAM refused to refresh groups (or visudo rejected the
    # content, or the rendered + on-disk bytes diverged). Operators saw
    # both "installed" AND "missing/invalid" in the same init output and
    # filed #1236. The fix: capture the installer result, then probe the
    # verifier, then print ONE line — either the success row or the
    # `manual-required` remediation row, never both.
    _init_sudoers_path=""
    _init_sudoers_install_rc=0
    _init_sudoers_install_ok=0
    _init_sudoers_path="$(bridge_daemon_control_install_sudoers 2>&1)" \
      || _init_sudoers_install_rc=$?
    _init_sudoers_status=""
    if command -v bridge_daemon_control_check_sudoers >/dev/null 2>&1; then
      _init_sudoers_status="$(bridge_daemon_control_check_sudoers 2>/dev/null || true)"
    fi
    if (( _init_sudoers_install_rc == 0 )) && [[ "$_init_sudoers_status" == "ok" ]]; then
      # #1230 (v0.15.0-beta4): logger output goes to stderr — see comment
      # at the plugins-seed printf above for the full rationale.
      printf '[init] daemon-refresh sudoers: installed at %s (verifier=ok)\n' "$_init_sudoers_path" >&2
      printf '[init] daemon_group_refresh_sudoers=ok\n' >&2
      _init_sudoers_install_ok=1
    else
      # Either install failed, or install succeeded but verifier rejected
      # the result. Surface manual-required + actionable remediation.
      # Do NOT emit an "installed" line — that is the #1236 contradiction.
      _init_sudoers_reason="$_init_sudoers_status"
      [[ -z "$_init_sudoers_reason" ]] && _init_sudoers_reason="missing"
      if (( _init_sudoers_install_rc != 0 )); then
        # Installer itself failed — surface its output for the operator.
        [[ -n "$_init_sudoers_path" ]] && printf '[init] daemon-refresh sudoers installer output: %s\n' "$_init_sudoers_path" >&2
        bridge_init_append_warning "daemon-refresh sudoers: manual-required (installer rc=$_init_sudoers_install_rc, verifier=$_init_sudoers_reason). Re-run: agent-bridge init sudoers daemon-refresh --apply"
      else
        # Install returned 0 but verifier disagrees — render+visudo mismatch
        # or sudo/PAM refused the probe. Record the path so the operator
        # can inspect it, but do NOT call it "installed".
        bridge_init_append_warning "daemon-refresh sudoers: manual-required (verifier=$_init_sudoers_reason at $_init_sudoers_path). Re-run: agent-bridge init sudoers daemon-refresh --apply (Linux+visudo required) — the daemon will fall back to queue-only-fallback for supp-groups refresh until this clears."
      fi
      # #1230 (v0.15.0-beta4): logger output goes to stderr.
      printf '[init] daemon-refresh sudoers: manual-required (verifier=%s)\n' "$_init_sudoers_reason" >&2
      printf '[init] daemon_group_refresh_sudoers=%s\n' "$_init_sudoers_reason" >&2
    fi

    # Beta20 L2 Variant 3A r4 — when the daemon-refresh sudoers landed,
    # regenerate the systemd-user unit with the sudo-wrapped ExecStart
    # so subsequent systemd-driven daemon starts cross the PAM refresh
    # boundary. Without this, a stale systemd-user manager re-spawns
    # the daemon with frozen supp groups and the r3 ad-hoc sudo
    # restart from the runtime helper would lose the race with
    # Restart=always. The install-daemon-systemd.sh auto-detects the
    # sudoers drop-in and renders the sudo-wrapped unit on its own;
    # we just re-run --apply + reload + restart-if-active. Non-fatal
    # — failure leaves the operator with the legacy direct unit and a
    # clear remediation path.
    if (( _init_sudoers_install_ok == 1 )) \
       && command -v systemctl >/dev/null 2>&1; then
      _init_systemd_rc=0
      _init_systemd_stderr=""
      _init_systemd_stderr_file=""
      _init_systemd_stderr_file="$(mktemp "${TMPDIR:-/tmp}/agb-init-systemd.XXXXXX" 2>/dev/null || printf '%s' "/tmp/agb-init-systemd.$$.$RANDOM")"
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-daemon-systemd.sh" \
        --bridge-home "$BRIDGE_HOME" --apply \
        2>"$_init_systemd_stderr_file" \
        || _init_systemd_rc=$?
      _init_systemd_stderr="$(cat "$_init_systemd_stderr_file" 2>/dev/null || printf '')"
      # Forward captured stderr to operator-visible stderr so warnings
      # from the helper script aren't swallowed. The mode= grep below
      # uses the same captured buffer.
      [[ -n "$_init_systemd_stderr" ]] && printf '%s\n' "$_init_systemd_stderr" >&2
      rm -f "$_init_systemd_stderr_file" 2>/dev/null || true
      # #1228 (v0.15.0-beta4): parse the machine-readable `mode=` line
      # the helper emits so the operator-facing message reflects what
      # was ACTUALLY written, not what we wished was written. Prior
      # init unconditionally claimed "regenerated (sudo-self) and
      # restarted" even when probe_sudo_self_refresh dropped the unit
      # back to legacy ExecStart — that lie was the operator-confusion
      # vector documented in KNOWN_ISSUES.md §28.
      _init_systemd_mode="$(printf '%s\n' "$_init_systemd_stderr" | sed -n 's/^mode=//p' | tail -n 1)"
      if (( _init_systemd_rc == 0 )); then
        if systemctl --user is-active --quiet agent-bridge-daemon.service 2>/dev/null; then
          systemctl --user daemon-reload || true
          systemctl --user restart agent-bridge-daemon.service \
            || bridge_init_append_warning "systemctl --user restart agent-bridge-daemon.service failed after unit regen — retry manually with: systemctl --user restart agent-bridge-daemon.service"
          # #1228 + #1230 (v0.15.0-beta4): logger output to stderr,
          # message reflects the actual mode= the helper reported.
          if [[ "$_init_systemd_mode" == "sudo-self" ]]; then
            printf '[init] systemd-user unit regenerated (mode=sudo-self) and restarted\n' >&2
          else
            printf '[init] systemd-user unit regenerated (mode=%s) and restarted — supplementary-group refresh will NOT cross PAM\n' "${_init_systemd_mode:-unknown}" >&2
            bridge_init_append_warning "systemd-user unit landed in mode=${_init_systemd_mode:-unknown} (not sudo-self) — daemon supp-group refresh will not auto-recover after \`agent create --linux-user\`. Run: agent-bridge init sudoers daemon-refresh --apply"
          fi
        else
          if [[ "$_init_systemd_mode" == "sudo-self" ]]; then
            printf '[init] systemd-user unit regenerated (mode=sudo-self) — service not active, will pick up on next start\n' >&2
          else
            printf '[init] systemd-user unit regenerated (mode=%s) — service not active\n' "${_init_systemd_mode:-unknown}" >&2
            bridge_init_append_warning "systemd-user unit landed in mode=${_init_systemd_mode:-unknown} (not sudo-self). Run: agent-bridge init sudoers daemon-refresh --apply"
          fi
        fi
      else
        bridge_init_append_warning "install-daemon-systemd.sh --apply returned rc=$_init_systemd_rc — unit may still carry legacy ExecStart. Re-run: $BRIDGE_HOME/scripts/install-daemon-systemd.sh --bridge-home $BRIDGE_HOME --apply"
      fi
    fi
  fi

  # Track D follow-up to #713 / #809, follow-on to #833: auto-register the
  # picker-sweep bridge-native cron. The helper is idempotent (short-circuits
  # when a job titled `picker-sweep` already exists), and the registered cron
  # payload sets `BRIDGE_PICKER_SWEEP_ENABLED=1` — that env var wins against
  # the runtime host_profile=dev default-skip in scripts/picker-sweep.sh, so
  # the sweep runs once it is registered. Registration itself, however, is
  # gated on the cron target `<admin>-dev` existing in the roster (see
  # lib/bridge-init-default-crons.sh): after issue #1052 that pair is
  # auto-provisioned just above ONLY on a `server` host with the codex CLI
  # present, so a server+codex install registers the sweep in this same init
  # run. A `dev` install (admin-only by design) or a codex-absent host has no
  # `<admin>-dev` pair, so the helper logs a skip; the sweep is registered
  # later when the operator creates the pair by hand, or when a server host
  # with the codex CLI re-runs `bridge-bootstrap.sh`. Operators who want the
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
    if ((${#teams_allow_from[@]} > 0)) || ((${#teams_conversations[@]} > 0)) || [[ -n "$channel_account" ]] || { [[ -n "$teams_app_id" ]] && { [[ -n "$teams_app_password_file" ]] || [[ -n "${BRIDGE_TEAMS_APP_PASSWORD:-}" ]]; }; } || bridge_init_runtime_present teams "$admin_agent"; then
      setup_args=(teams "$admin_agent")
      for item in "${teams_allow_from[@]}"; do
        setup_args+=(--allow-from "$item")
      done
      for item in "${teams_conversations[@]}"; do
        setup_args+=(--conversation "$item")
      done
      [[ -n "$teams_app_id" ]] && setup_args+=(--app-id "$teams_app_id")
      # Forward the client secret by path only — BRIDGE_TEAMS_APP_PASSWORD, if
      # set, is inherited by the bridge-setup.sh child without appearing in argv.
      [[ -n "$teams_app_password_file" ]] && setup_args+=(--app-password-file "$teams_app_password_file")
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
