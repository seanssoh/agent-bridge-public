#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# lib/bridge-setup-wizard.sh — v0.15.0-beta4 Lane B (issues #1268, #1271).
#
# Interactive onboarding wizard for the `teams` and `ms365` channels.
# Both channels require site-specific values (messaging endpoint, webhook
# host/port, OAuth redirect URI, ...) that the codebase cannot pick
# sensible defaults for. Before this helper, fresh-install operators ran
# `setup teams|ms365 ... --yes` and got `write_status: ok` even when the
# webhook bound to 127.0.0.1, the messaging endpoint was unset, and the
# Bot Framework registration silently dropped every inbound DM. The fix
# is a 4-step wizard (ask → probe → write → summarise) parameterised by
# channel kind, plus auto-mode validation that fails loud with an
# enumerated list of missing required values when an operator pipes
# `--yes` without providing all site-specific flags.
#
# Public entry points:
#   bridge_setup_wizard_required_fields <channel>
#       Echoes the canonical required-field list for the channel. Read by
#       the auto-mode validator and the smoke pin.
#   bridge_setup_wizard_is_auto_mode <args...>
#       0 if `--yes` appears anywhere in argv (auto-mode contract), 1
#       otherwise. Independent of TTY probe.
#   bridge_setup_wizard_is_interactive_tty
#       0 if BOTH stdin and stdout are TTYs (the only safe interactive
#       prompt context); 1 otherwise.
#   bridge_setup_wizard_validate_auto <channel> <args...>
#       In auto-mode, scans argv for the per-channel required flags and
#       calls `bridge_die` with a structured "missing: …" list if any
#       are absent. No-op when interactive (caller decides routing).
#   bridge_setup_wizard_run_teams <agent> <args_in_nameref> <args_out_nameref>
#       Interactive wizard for `setup teams`. Reads existing values via
#       the python inspector, prompts for each missing site-specific
#       field with guidance, and appends `--<flag> <value>` pairs to the
#       caller's argv-out array. Caller then invokes the python wizard
#       with `--yes` plus the assembled args.
#   bridge_setup_wizard_run_ms365 <agent> <args_in_nameref> <args_out_nameref>
#       Interactive wizard for `setup ms365`. Same shape as the teams
#       variant.
#   bridge_setup_wizard_post_summary_teams <messaging_endpoint> <webhook_host> <webhook_port>
#   bridge_setup_wizard_post_summary_ms365 <redirect_uri> <client_id>
#       Step 4 — outstanding manual-action summary printed AFTER the
#       python wizard returns success. Writes to stderr so the structured
#       stdout stream (consumed by patch admin agent) stays clean.
#
# Sourcing contract: only sourced by `bridge-setup.sh`. Depends on
# `bridge_die` / `bridge_warn` / `bridge_info` from lib/bridge-core.sh,
# which `bridge-lib.sh` has already sourced when `bridge-setup.sh` reads
# this file.

if [[ -n "${_BRIDGE_SETUP_WIZARD_SOURCED:-}" ]]; then
  return 0
fi
_BRIDGE_SETUP_WIZARD_SOURCED=1

# --------------------------------------------------------------------
# Field tables. Keep these in lockstep with bridge-setup.py argparse.
# Each entry is `<cli-flag>` (no leading dashes; the wizard prints the
# canonical `--flag` form when it surfaces the missing list).
# --------------------------------------------------------------------

# Required teams fields — issue #1268 explicit list. Captures every value
# the codebase cannot guess for an arbitrary install:
#   app-id              — Azure Bot Service registration
#   app-password-file   — secret material, never on argv
#   tenant-id           — Azure Entra tenant
#   allow-from          — at least one AAD user/object id (the bot's DM
#                         allowlist; an empty allowlist silently drops
#                         every inbound DM)
#   messaging-endpoint  — Bot Framework messaging endpoint registered in
#                         the Bot Service registration. The Bot Framework
#                         validates the token against THIS URL.
#   webhook-host        — interface the plugin binds to (127.0.0.1 is
#                         NOT reachable from Bot Framework)
#   webhook-port        — TCP port the plugin listens on
_BRIDGE_SETUP_WIZARD_REQUIRED_TEAMS=(
  app-id
  app-password-file
  tenant-id
  allow-from
  messaging-endpoint
  webhook-host
  webhook-port
)

# Required ms365 fields — issue #1271 explicit list, refined by
# issue #1355 (default-scopes moved to protocol-convention default).
# Names match the operator-facing CLI flags in
# `bridge-setup.py:ms365_parser` so a missing-value report names the
# exact `--<flag>` the operator types:
#   client-id           — Entra App registration Application (client) ID
#   client-secret-file  — secret material, never on argv
#   tenant-id           — Azure Entra tenant
#   redirect-uri        — must be registered in Entra app Authentication.
#                         Cannot be derived for arbitrary deployments —
#                         operator must know the URL the Entra app
#                         expects.
#
# Removed in #1355 (now protocol-convention default in cmd_ms365):
#   default-scopes      — MS Graph minimal scope set
#                         (Mail.Read / Mail.Send / Calendars.ReadWrite /
#                         offline_access) is the de-facto MS365 baseline,
#                         not a site-specific value. Auto-mode now falls
#                         back to `MS365_CONVENTION_DEFAULT_SCOPES` with
#                         `default_scopes_source: convention-default` on
#                         the wizard summary; operators with non-default
#                         Graph permissions can still override with
#                         `--default-scopes "..."`. See bridge-setup.py
#                         MS365_CONVENTION_DEFAULT_SCOPES.
_BRIDGE_SETUP_WIZARD_REQUIRED_MS365=(
  client-id
  client-secret-file
  tenant-id
  redirect-uri
)

bridge_setup_wizard_required_fields() {
  local channel="${1:-}"
  case "$channel" in
    teams)
      printf '%s\n' "${_BRIDGE_SETUP_WIZARD_REQUIRED_TEAMS[@]}"
      ;;
    ms365)
      printf '%s\n' "${_BRIDGE_SETUP_WIZARD_REQUIRED_MS365[@]}"
      ;;
    *)
      bridge_die "[setup wizard] 알 수 없는 채널: ${channel}"
      ;;
  esac
}

# --------------------------------------------------------------------
# Mode detection.
# --------------------------------------------------------------------

bridge_setup_wizard_is_auto_mode() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--yes" ]]; then
      return 0
    fi
  done
  return 1
}

bridge_setup_wizard_is_interactive_tty() {
  # Both ends required. A CI pipe (stdin=pipe, stdout=tty) would still
  # block on `read`; conversely a `read | cat` (stdin=tty, stdout=pipe)
  # would hide prompts. Require BOTH so the wizard never wedges.
  if [[ -t 0 && -t 1 ]]; then
    return 0
  fi
  return 1
}

# Tiny argv scanner. Echoes 1 if the flag (with a non-empty value) is in
# argv, 0 otherwise. Treats `--flag value` and `--flag=value` the same.
# For `action="append"` style flags (e.g. --allow-from), one presence is
# enough to count as supplied.
_bridge_setup_wizard_argv_has() {
  local needle="$1"
  shift
  local i
  for (( i = 1; i <= $#; i++ )); do
    local cur="${!i}"
    if [[ "$cur" == "--${needle}" ]]; then
      # Need a non-empty value after this flag.
      local next_idx=$((i + 1))
      if (( next_idx <= $# )); then
        local nxt="${!next_idx}"
        if [[ -n "$nxt" && "$nxt" != --* ]]; then
          printf '1'
          return 0
        fi
      fi
    elif [[ "$cur" == --"${needle}"=* ]]; then
      local val="${cur#--${needle}=}"
      if [[ -n "$val" ]]; then
        printf '1'
        return 0
      fi
    fi
  done
  printf '0'
}

# Tiny argv scanner companion: echo the value of `--<flag>` from argv,
# accepting both `--flag value` and `--flag=value` shapes. Empty string
# if not present. Returns LAST occurrence (so a later override wins,
# matching argparse semantics).
_bridge_setup_wizard_argv_value() {
  local needle="$1"
  shift
  local found=""
  local i
  for (( i = 1; i <= $#; i++ )); do
    local cur="${!i}"
    if [[ "$cur" == "--${needle}" ]]; then
      local next_idx=$((i + 1))
      if (( next_idx <= $# )); then
        local nxt="${!next_idx}"
        if [[ -n "$nxt" && "$nxt" != --* ]]; then
          found="$nxt"
        fi
      fi
    elif [[ "$cur" == --"${needle}"=* ]]; then
      found="${cur#--${needle}=}"
    fi
  done
  printf '%s' "$found"
}

bridge_setup_wizard_validate_auto() {
  local channel="${1:-}"
  shift || true
  local -a required=()
  case "$channel" in
    teams)
      required=("${_BRIDGE_SETUP_WIZARD_REQUIRED_TEAMS[@]}")
      ;;
    ms365)
      required=("${_BRIDGE_SETUP_WIZARD_REQUIRED_MS365[@]}")
      ;;
    *)
      bridge_die "[setup wizard] 알 수 없는 채널: ${channel}"
      ;;
  esac

  local -a missing=()
  local field
  for field in "${required[@]}"; do
    if [[ "$(_bridge_setup_wizard_argv_has "$field" "$@")" != "1" ]]; then
      missing+=("--${field}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    bridge_die "[setup ${channel}] 자동 모드(--yes)에서 필수 값 누락: ${missing[*]} (인터랙티브 모드로 실행하거나 모든 flag를 명시하세요)"
  fi
}

# --------------------------------------------------------------------
# Interactive prompts.
# --------------------------------------------------------------------

# bridge_setup_wizard_prompt — read one line from the operator. Echoes
# stripped value (or default if empty). Reads from /dev/tty so a caller
# that piped --yes-less stdin still gets a real prompt; the TTY guard in
# `bridge_setup_wizard_is_interactive_tty` already rejected pipes, so
# /dev/tty is guaranteed available here.
_bridge_setup_wizard_prompt() {
  local message="$1"
  local default_value="${2:-}"
  local reply=""
  local rendered_prompt
  if [[ -n "$default_value" ]]; then
    rendered_prompt="${message} [${default_value}]: "
  else
    rendered_prompt="${message}: "
  fi
  # Stderr for the prompt so stdout stays the wizard's structured channel.
  printf '%s' "$rendered_prompt" >&2
  # `read` from /dev/tty so we never accidentally consume the caller's
  # stdin (e.g. a heredoc the test smoke uses to drive prompts).
  IFS= read -r reply < /dev/tty || reply=""
  reply="${reply#"${reply%%[![:space:]]*}"}"
  reply="${reply%"${reply##*[![:space:]]}"}"
  if [[ -z "$reply" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$reply"
  fi
}

_bridge_setup_wizard_section() {
  printf '\n[setup wizard] %s\n' "$1" >&2
}

bridge_setup_wizard_run_teams() {
  local agent="${1:-}"
  local out_array_name="${2:-}"
  [[ -n "$agent" ]] || bridge_die "[setup wizard] agent name required"
  [[ -n "$out_array_name" ]] || bridge_die "[setup wizard] out array name required"

  _bridge_setup_wizard_section "Teams 채널 인터랙티브 셋업 (agent=${agent})"
  printf '  step 1: 필수 값 입력 (Azure Bot Service registration 참고)\n' >&2

  local app_id
  app_id="$(_bridge_setup_wizard_prompt "Azure Bot Application ID (Azure Portal → Bot Services → <bot> → Configuration → Microsoft App ID)" "")"
  if [[ -z "$app_id" ]]; then
    bridge_die "[setup teams] Azure Bot Application ID는 필수입니다."
  fi

  local app_password_file
  app_password_file="$(_bridge_setup_wizard_prompt "Bot client secret를 담은 파일 경로 (--app-password-file)" "")"
  if [[ -z "$app_password_file" ]]; then
    bridge_die "[setup teams] client secret 파일 경로(--app-password-file)는 필수입니다."
  fi
  if [[ ! -f "$app_password_file" ]]; then
    bridge_die "[setup teams] secret 파일을 찾을 수 없습니다: ${app_password_file}"
  fi

  local tenant_id
  tenant_id="$(_bridge_setup_wizard_prompt "Azure Tenant ID (Azure Portal → Microsoft Entra ID → Overview → Tenant ID)" "")"
  if [[ -z "$tenant_id" ]]; then
    bridge_die "[setup teams] Azure Tenant ID는 필수입니다."
  fi

  local allow_from
  allow_from="$(_bridge_setup_wizard_prompt "DM 허용할 AAD 사용자 object ID (MS Graph /me → id). 다수면 쉼표로 구분" "")"
  if [[ -z "$allow_from" ]]; then
    bridge_die "[setup teams] allow_from은 최소 1개 필요합니다. 비어 있으면 모든 inbound DM이 silent drop 됩니다."
  fi

  local messaging_endpoint
  messaging_endpoint="$(_bridge_setup_wizard_prompt "Bot Framework messaging endpoint URL (Azure Portal → Bot Services → <bot> → Configuration → Messaging endpoint, https://<reverse-proxy>/api/messages 형태)" "")"
  if [[ -z "$messaging_endpoint" ]]; then
    bridge_die "[setup teams] messaging_endpoint는 필수입니다. Bot Service registration의 URL과 정확히 일치해야 합니다."
  fi
  case "$messaging_endpoint" in
    https://*|http://*) ;;
    *)
      bridge_die "[setup teams] messaging_endpoint는 http(s):// URL이어야 합니다: ${messaging_endpoint}"
      ;;
  esac

  local webhook_host
  webhook_host="$(_bridge_setup_wizard_prompt "Webhook bind host (0.0.0.0 = 모든 인터페이스, 127.0.0.1은 외부 도달 불가)" "0.0.0.0")"
  if [[ -z "$webhook_host" ]]; then
    bridge_die "[setup teams] webhook_host가 필수입니다."
  fi
  if [[ "$webhook_host" == "127.0.0.1" || "$webhook_host" == "localhost" ]]; then
    bridge_warn "[setup teams] webhook_host=${webhook_host}는 loopback입니다 — reverse-proxy 패턴이 아니라면 Bot Framework가 inbound DM을 도달시킬 수 없습니다."
  fi

  local webhook_port
  webhook_port="$(_bridge_setup_wizard_prompt "Webhook TCP port (Bot Framework 표준 3978)" "3978")"
  if ! [[ "$webhook_port" =~ ^[0-9]{2,5}$ ]]; then
    bridge_die "[setup teams] webhook_port는 TCP 포트 번호여야 합니다: ${webhook_port}"
  fi

  # Hand the assembled args back to the caller via nameref. We can't use
  # `local -n` in older bash, so use `eval` with the array name.
  eval "${out_array_name}+=(--app-id \"\$app_id\" \
                            --app-password-file \"\$app_password_file\" \
                            --tenant-id \"\$tenant_id\" \
                            --allow-from \"\$allow_from\" \
                            --messaging-endpoint \"\$messaging_endpoint\" \
                            --webhook-host \"\$webhook_host\" \
                            --webhook-port \"\$webhook_port\" \
                            --yes)"

  # Cache the chosen messaging_endpoint / webhook_host / webhook_port in
  # process-scoped globals for the post-summary printer (avoids re-parsing
  # the python wizard's stdout).
  _BRIDGE_SETUP_WIZARD_LAST_TEAMS_MSG_ENDPOINT="$messaging_endpoint"
  _BRIDGE_SETUP_WIZARD_LAST_TEAMS_WEBHOOK_HOST="$webhook_host"
  _BRIDGE_SETUP_WIZARD_LAST_TEAMS_WEBHOOK_PORT="$webhook_port"
  export _BRIDGE_SETUP_WIZARD_LAST_TEAMS_MSG_ENDPOINT \
         _BRIDGE_SETUP_WIZARD_LAST_TEAMS_WEBHOOK_HOST \
         _BRIDGE_SETUP_WIZARD_LAST_TEAMS_WEBHOOK_PORT
}

bridge_setup_wizard_run_ms365() {
  local agent="${1:-}"
  local out_array_name="${2:-}"
  [[ -n "$agent" ]] || bridge_die "[setup wizard] agent name required"
  [[ -n "$out_array_name" ]] || bridge_die "[setup wizard] out array name required"

  _bridge_setup_wizard_section "MS365 채널 인터랙티브 셋업 (agent=${agent})"
  printf '  step 1: 필수 값 입력 (Entra App registration 참고)\n' >&2

  local client_id
  client_id="$(_bridge_setup_wizard_prompt "Entra App Application (client) ID (Azure Portal → App registrations → <app> → Overview)" "")"
  if [[ -z "$client_id" ]]; then
    bridge_die "[setup ms365] client_id는 필수입니다."
  fi

  local client_secret_file
  client_secret_file="$(_bridge_setup_wizard_prompt "Entra App client secret를 담은 파일 경로 (--client-secret-file)" "")"
  if [[ -z "$client_secret_file" ]]; then
    bridge_die "[setup ms365] client secret 파일 경로(--client-secret-file)는 필수입니다."
  fi
  if [[ ! -f "$client_secret_file" ]]; then
    bridge_die "[setup ms365] secret 파일을 찾을 수 없습니다: ${client_secret_file}"
  fi

  local tenant_id
  tenant_id="$(_bridge_setup_wizard_prompt "Azure Tenant ID (Azure Portal → Microsoft Entra ID → Overview → Tenant ID)" "")"
  if [[ -z "$tenant_id" ]]; then
    bridge_die "[setup ms365] Azure Tenant ID는 필수입니다."
  fi

  local redirect_uri
  redirect_uri="$(_bridge_setup_wizard_prompt "OAuth redirect URI (Azure Portal → App registrations → <app> → Authentication → Redirect URIs에 등록된 값과 동일, 보통 https://<bot-host>/auth/callback)" "")"
  if [[ -z "$redirect_uri" ]]; then
    bridge_die "[setup ms365] redirect_uri는 필수입니다. Entra app Authentication에 등록된 URL과 정확히 일치해야 합니다."
  fi
  case "$redirect_uri" in
    https://*|http://*) ;;
    *)
      bridge_die "[setup ms365] redirect_uri는 http(s):// URL이어야 합니다: ${redirect_uri}"
      ;;
  esac

  # Issue #1355: --default-scopes is now protocol-convention default
  # (Mail+Calendar minimal baseline lives in bridge-setup.py's
  # MS365_CONVENTION_DEFAULT_SCOPES). Empty input falls back to the
  # python wizard's convention default; a non-empty override is
  # forwarded as `--default-scopes "$scope"`. The interactive prompt
  # still surfaces the canonical baseline so operators see what they
  # are accepting by pressing Enter.
  local scope
  scope="$(_bridge_setup_wizard_prompt "MS Graph scope (공백으로 구분, default: MS Graph minimal — Mail.Read Mail.Send Calendars.ReadWrite offline_access)" "")"

  # Build the argv. --default-scopes is conditional now.
  local -a _ms365_extra=()
  if [[ -n "$scope" ]]; then
    _ms365_extra=(--default-scopes "$scope")
  fi

  # Disable SC2207 / quoting style noise — we splice the extra array
  # in-place using bash's positional array expansion.
  eval "${out_array_name}+=(--client-id \"\$client_id\" \
                            --client-secret-file \"\$client_secret_file\" \
                            --tenant-id \"\$tenant_id\" \
                            --redirect-uri \"\$redirect_uri\" \
                            \"\${_ms365_extra[@]}\" \
                            --yes)"

  _BRIDGE_SETUP_WIZARD_LAST_MS365_REDIRECT_URI="$redirect_uri"
  _BRIDGE_SETUP_WIZARD_LAST_MS365_CLIENT_ID="$client_id"
  export _BRIDGE_SETUP_WIZARD_LAST_MS365_REDIRECT_URI \
         _BRIDGE_SETUP_WIZARD_LAST_MS365_CLIENT_ID
}

# --------------------------------------------------------------------
# Step 4 — outstanding manual-action summary. Stderr to keep stdout
# clean for callers that parse the python wizard's structured output.
# --------------------------------------------------------------------

bridge_setup_wizard_post_summary_teams() {
  local messaging_endpoint="${1:-${_BRIDGE_SETUP_WIZARD_LAST_TEAMS_MSG_ENDPOINT:-}}"
  local webhook_host="${2:-${_BRIDGE_SETUP_WIZARD_LAST_TEAMS_WEBHOOK_HOST:-}}"
  local webhook_port="${3:-${_BRIDGE_SETUP_WIZARD_LAST_TEAMS_WEBHOOK_PORT:-}}"

  # printf-grouped (no heredoc) — footgun #11 / brief-mandated "0 heredoc
  # in changed files". The printf format strings carry literal newlines
  # so the rendered output matches the previous heredoc body byte-for-byte
  # except for the leading blank line which is the first printf.
  {
    printf '\n'
    printf '[setup teams] step 4: 남은 manual action — 진행 후에야 inbound DM이 도달합니다.\n'
    printf '  1. Azure Portal → Bot Services → <bot> → Configuration → Messaging endpoint를\n'
    printf "     '%s'로 설정했는지 확인하세요.\n" "${messaging_endpoint:-(unset)}"
    printf '  2. reverse proxy / 외부 라우팅이 이 호스트의 %s:%s로\n' \
      "${webhook_host:-(unset)}" "${webhook_port:-(unset)}"
    printf '     forward하는지 확인하세요. (loopback이면 외부 도달 불가)\n'
    printf '  3. Teams DM 한 통으로 round-trip 검증을 진행하세요. plugin 로그가\n'
    printf "     'inbound activity' 라인을 찍어야 정상입니다.\n"
  } >&2
}

bridge_setup_wizard_post_summary_ms365() {
  local redirect_uri="${1:-${_BRIDGE_SETUP_WIZARD_LAST_MS365_REDIRECT_URI:-}}"
  local client_id="${2:-${_BRIDGE_SETUP_WIZARD_LAST_MS365_CLIENT_ID:-}}"

  # printf-grouped (no heredoc) — footgun #11 / brief-mandated "0 heredoc
  # in changed files". Output is byte-equivalent to the previous heredoc.
  {
    printf '\n'
    printf '[setup ms365] step 4: 남은 manual action — 진행 후에야 OAuth consent flow가 동작합니다.\n'
    printf '  1. Azure Portal → App registrations → %s →\n' "${client_id:-<your-app>}"
    printf "     Authentication → Redirect URIs에 '%s'가 등록되어\n" "${redirect_uri:-(unset)}"
    printf '     있는지 확인하세요. 등록이 누락되면 AADSTS50011가 발생합니다.\n'
    printf '  2. ms365 pair_start로 OAuth authorize URL을 받아 브라우저에서 consent를\n'
    printf '     완료하세요. 첫 round-trip 후 .ms365/state.json에 토큰이 기록됩니다.\n'
  } >&2
}

# --------------------------------------------------------------------
# Step 3 — connectivity probes (v0.15.0-beta4 Lane B R2, codex r1
# BLOCKING fix). The wizard's job is to refuse to write any state file
# until the operator-supplied values are actually reachable. Two probe
# families:
#
#   teams:
#     1. local-bind probe — can we actually open `webhook_host:webhook_port`?
#        Loopback values usually pass this and are filtered by the wizard
#        prompt content-warn; the real catches are "port in use" and
#        "address not assigned to this host".
#     2. messaging_endpoint reachability — does the configured Bot
#        Framework messaging endpoint respond to a HEAD/POST within 10s?
#        We accept any HTTP response code (including 401/403/404/405) as
#        proof of reachability; only timeout / DNS failure / connection
#        refused fail the probe.
#
#   ms365:
#     1. redirect_uri reachability — does the configured OAuth callback
#        URL respond within 10s? Same semantics as the teams messaging
#        endpoint probe — any HTTP response = OK, transport-layer failure
#        = fail.
#
# Probe failure calls `bridge_die`. Operators who need to set up an
# air-gapped install can pass `--allow-probe-failure` (consumed by
# bridge-setup.sh; we surface a `bridge_warn` instead of dying).
# --------------------------------------------------------------------

# Returns 0 if argv contains --allow-probe-failure, 1 otherwise.
bridge_setup_wizard_has_allow_probe_failure() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--allow-probe-failure" ]]; then
      return 0
    fi
  done
  return 1
}

# _bridge_setup_wizard_die_or_warn <allow_failure> <message...>
#   allow_failure=1 → bridge_warn, return 1 (caller decides)
#   allow_failure=0 → bridge_die (does not return)
_bridge_setup_wizard_die_or_warn() {
  local allow_failure="${1:-0}"
  shift
  local msg="$*"
  if [[ "$allow_failure" == "1" ]]; then
    bridge_warn "${msg} (--allow-probe-failure 지정됨 — 그대로 진행하지만 외부 도달성을 운영자가 별도로 검증해야 합니다)"
    return 1
  fi
  bridge_die "${msg}"
}

# Probe scripts — kept as module-level scalars so we use Pattern B
# (`python3 -c "$SCRIPT"`) when CAPTURING output via $(...). The
# heredoc-stdin pattern (`python3 - <<'PY' ... PY`) is safe when NOT
# captured but wedges Bash 5.3.9 when wrapped in $(...) — see footgun
# #11 / lib/bridge-core.sh:186.
_BRIDGE_SETUP_WIZARD_PROBE_LOCAL_BIND_PY='
import socket, sys
host = sys.argv[1]
try:
    port = int(sys.argv[2])
except (TypeError, ValueError):
    print(f"invalid_port:{sys.argv[2]!r}", file=sys.stderr)
    sys.exit(2)
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((host, port))
    sock.listen(1)
    print("ok")
except OSError as exc:
    print(f"bind_failed:{exc.errno}:{exc.strerror}", file=sys.stderr)
    sys.exit(1)
finally:
    try:
        sock.close()
    except Exception:
        pass
'

_BRIDGE_SETUP_WIZARD_PROBE_REACHABILITY_PY='
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
url = sys.argv[1]
method = sys.argv[2] if len(sys.argv) > 2 else "POST"
if method == "POST":
    req = Request(
        url,
        data=b"{}",
        headers={
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-setup-wizard/r2",
        },
        method="POST",
    )
else:
    req = Request(
        url,
        headers={"User-Agent": "agent-bridge-setup-wizard/r2"},
        method=method,
    )
try:
    with urlopen(req, timeout=10) as resp:
        code = int(resp.getcode() or 0)
        print(f"ok:http_{code}")
except HTTPError as exc:
    # Application-level rejection counts as reachable.
    print(f"ok:http_{int(exc.code or 0)}")
except URLError as exc:
    print(f"unreachable:{exc.reason!r}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"unreachable:exception:{exc!r}", file=sys.stderr)
    sys.exit(1)
'

# bridge_setup_wizard_probe_teams_local_bind <host> <port> [allow_failure]
#
# Tries to open a listening socket on host:port using python3, then
# closes immediately. This catches: port already in use, address not
# assigned to this host, permission denied (low ports without
# capabilities). Loopback values are accepted because the prompt's
# content-warn already covered that — this probe answers "can the
# plugin EVER bind?".
bridge_setup_wizard_probe_teams_local_bind() {
  local host="${1:-}"
  local port="${2:-}"
  local allow_failure="${3:-0}"
  if [[ -z "$host" || -z "$port" ]]; then
    bridge_die "[setup teams] internal: probe_teams_local_bind은 host/port가 필요합니다."
  fi
  local probe_out=""
  local probe_rc=0
  probe_out="$(python3 -c "$_BRIDGE_SETUP_WIZARD_PROBE_LOCAL_BIND_PY" "$host" "$port" 2>&1)" || probe_rc=$?
  if (( probe_rc != 0 )); then
    _bridge_setup_wizard_die_or_warn "$allow_failure" \
      "[setup teams] webhook bind ${host}:${port} 실패 — 이미 사용 중이거나 권한 부족, 또는 호스트에 할당되지 않은 인터페이스입니다. (probe detail: ${probe_out})"
    return 1
  fi
  return 0
}

# bridge_setup_wizard_probe_teams_messaging_endpoint <url> [allow_failure]
#
# SCOPE (SSOT — see also PR #1285 body, beta5 backlog):
#   Reachability-only is the intended probe contract for beta4. We POST
#   {} with a 10s timeout and accept ANY HTTP response code (200, 401,
#   403, 404, 405, 500, ...) as proof that the operator's reverse proxy
#   + Bot Service registration + DNS are wired end-to-end enough to
#   route requests to this VM — Bot Framework itself responds 401 to
#   unauthenticated probes. We do NOT issue an HMAC-signed challenge
#   against the Bot Framework signing secret here — that is a separate
#   auth-layer validation, requires the secret to already be configured,
#   and is deferred to a beta5 enhancement. Transport-layer failures
#   (DNS, connect refused, timeout, TLS handshake) fail the probe.
bridge_setup_wizard_probe_teams_messaging_endpoint() {
  local endpoint="${1:-}"
  local allow_failure="${2:-0}"
  if [[ -z "$endpoint" ]]; then
    bridge_die "[setup teams] internal: probe_teams_messaging_endpoint는 URL이 필요합니다."
  fi
  local probe_out=""
  local probe_rc=0
  probe_out="$(python3 -c "$_BRIDGE_SETUP_WIZARD_PROBE_REACHABILITY_PY" "$endpoint" "POST" 2>&1)" || probe_rc=$?
  if (( probe_rc != 0 )); then
    _bridge_setup_wizard_die_or_warn "$allow_failure" \
      "[setup teams] messaging_endpoint reachability failed: ${endpoint} — Bot Service registration + reverse proxy + DNS를 확인하세요. (probe detail: ${probe_out})"
    return 1
  fi
  return 0
}

# bridge_setup_wizard_probe_ms365_redirect <redirect_uri> [allow_failure]
#
# HEAD probe with 10s timeout against the OAuth redirect URI. Same
# reachability semantics as teams: any HTTP response = OK, transport
# failure = fail. Catches typos in the host, missing reverse proxy
# registration, and unreachable cloud DNS.
bridge_setup_wizard_probe_ms365_redirect() {
  local redirect_uri="${1:-}"
  local allow_failure="${2:-0}"
  if [[ -z "$redirect_uri" ]]; then
    bridge_die "[setup ms365] internal: probe_ms365_redirect는 URL이 필요합니다."
  fi
  local probe_out=""
  local probe_rc=0
  probe_out="$(python3 -c "$_BRIDGE_SETUP_WIZARD_PROBE_REACHABILITY_PY" "$redirect_uri" "HEAD" 2>&1)" || probe_rc=$?
  if (( probe_rc != 0 )); then
    _bridge_setup_wizard_die_or_warn "$allow_failure" \
      "[setup ms365] redirect_uri reachability failed: ${redirect_uri} — Entra app Authentication에 redirect_uri 등록 + 호스트/DNS/reverse-proxy 확인. (probe detail: ${probe_out})"
    return 1
  fi
  return 0
}

# bridge_setup_wizard_run_teams_probes <argv...>
#
# Public entry point — extracts webhook_host / webhook_port /
# messaging_endpoint from argv and runs both teams probes. Honors
# --allow-probe-failure (warn instead of die). Caller passes the full
# py_args array.
bridge_setup_wizard_run_teams_probes() {
  local allow_failure=0
  if bridge_setup_wizard_has_allow_probe_failure "$@"; then
    allow_failure=1
  fi
  local webhook_host webhook_port messaging_endpoint
  webhook_host="$(_bridge_setup_wizard_argv_value "webhook-host" "$@")"
  webhook_port="$(_bridge_setup_wizard_argv_value "webhook-port" "$@")"
  messaging_endpoint="$(_bridge_setup_wizard_argv_value "messaging-endpoint" "$@")"
  if [[ -z "$webhook_host" || -z "$webhook_port" || -z "$messaging_endpoint" ]]; then
    bridge_die "[setup teams] internal: probe entry-point requires webhook-host / webhook-port / messaging-endpoint all set."
  fi
  bridge_setup_wizard_probe_teams_local_bind "$webhook_host" "$webhook_port" "$allow_failure" || true
  bridge_setup_wizard_probe_teams_messaging_endpoint "$messaging_endpoint" "$allow_failure" || true
}

# bridge_setup_wizard_run_ms365_probes <argv...>
#
# Public entry point — extracts redirect-uri and runs the ms365 probe.
bridge_setup_wizard_run_ms365_probes() {
  local allow_failure=0
  if bridge_setup_wizard_has_allow_probe_failure "$@"; then
    allow_failure=1
  fi
  local redirect_uri
  redirect_uri="$(_bridge_setup_wizard_argv_value "redirect-uri" "$@")"
  if [[ -z "$redirect_uri" ]]; then
    bridge_die "[setup ms365] internal: probe entry-point requires redirect-uri to be set."
  fi
  bridge_setup_wizard_probe_ms365_redirect "$redirect_uri" "$allow_failure" || true
}
