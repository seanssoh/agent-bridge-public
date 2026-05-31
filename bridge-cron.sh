#!/usr/bin/env bash
# bridge-cron.sh — bridge-owned cron inventory, migration, and queue adapters

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") inventory [--agent <agent>] [--family <family>] [--mode recurring|one-shot|all] [--enabled yes|no|all] [--limit <count>] [--json]
  $(basename "$0") show <job-name-or-id> [--json]
  $(basename "$0") import [--source-jobs-file <path>] [--dry-run]
  $(basename "$0") list [--agent <bridge-agent>] [--enabled yes|no|all] [--limit <count>] [--json]
  $(basename "$0") create --agent <bridge-agent> (--schedule "<cron-expr>" | --at "<iso-datetime>") --title "<title>" [--payload "<text>" | --payload-file <path>] [--kind text|shell --script <path> --run-as-agent <agent> [--script-arg <arg>] [--script-env KEY=VALUE] [--timeout <seconds>] [--output-cap <bytes>]] [--tz <iana-tz>] [--delete-after-run]
  $(basename "$0") update <job-id> [--agent <bridge-agent>] [--schedule "<cron-expr>" | --at "<iso-datetime>"] [--title "<title>"] [--payload "<text>" | --payload-file <path>] [--kind text|shell --script <path> --run-as-agent <agent> [--script-arg <arg>] [--script-env KEY=VALUE] [--timeout <seconds>] [--output-cap <bytes>] [--allow-kind-transition]] [--tz <iana-tz>] [--enable|--disable] [--delete-after-run|--keep-after-run]
  $(basename "$0") delete <job-id>
  $(basename "$0") rebalance-memory-daily [--jobs-file <path>] [--schedule "<cron-expr>"] [--tz <iana-tz>] [--dry-run] [--json]
  $(basename "$0") migrate-payloads --jsonl-aware [--jobs-file <path>] [--dry-run] [--json]
  $(basename "$0") enqueue <job-name-or-id> [--slot <slot-key>] [--target <bridge-agent>] [--from <actor>] [--priority normal|high] [--dry-run]
  $(basename "$0") sync [--dry-run] [--json] [--since <iso-datetime>] [--now <iso-datetime>]
  $(basename "$0") run-subagent <run-id> [--dry-run]
  $(basename "$0") errors report [--agent <agent>] [--family <family>] [--limit <count>] [--json]
  $(basename "$0") cleanup report [--mode expired-one-shot] [--json]
  $(basename "$0") cleanup prune [--mode expired-one-shot] [--dry-run]

Notes:
  --kind shell (with --run-as-agent) runs a script under a dedicated isolated
  OS UID and REQUIRES a linux-user isolated agent (iso v2 — Linux only). It is
  unavailable on macOS / non-iso installs. To run a script on a schedule
  without iso, use OS crontab (recommended) or a --kind text cron whose payload
  runs 'bash <script>' against a non-Claude (codex) agent. See OPERATIONS.md
  "Scheduled shell scripts without iso v2".
EOF
}

run_inventory() {
  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  local py_args=(
    inventory
    --jobs-file "$jobs_file"
  )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--family|--mode|--enabled|--limit)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        py_args+=("$1" "$2")
        shift 2
        ;;
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_cron_source_jobs "$jobs_file"
  bridge_cron_python "${py_args[@]}"
}

run_show() {
  local job_ref="${1:-}"
  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  local py_args=(
    show
    --jobs-file "$jobs_file"
  )

  shift || true
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") show <job-name-or-id> [--json]"
  py_args+=("$job_ref")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_cron_source_jobs "$jobs_file"
  bridge_cron_python "${py_args[@]}"
}

run_import() {
  local source_jobs_file="$BRIDGE_SOURCE_CRON_JOBS_FILE"
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-jobs-file)
        [[ $# -lt 2 ]] && bridge_die "--source-jobs-file 뒤에 값을 지정하세요."
        source_jobs_file="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 import 옵션입니다: $1"
        ;;
    esac
  done

  [[ -f "$source_jobs_file" ]] || bridge_die "source cron jobs 파일이 없습니다: $source_jobs_file"
  local py_args=(
    native-import
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    --source-jobs-file "$source_jobs_file"
  )
  if [[ $dry_run -eq 1 ]]; then
    py_args+=(--dry-run)
  fi
  bridge_cron_python "${py_args[@]}"
}

run_list() {
  local py_args=(
    native-list
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
  )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--enabled|--limit)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        py_args+=("$1" "$2")
        shift 2
        ;;
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        _hint="$(bridge_suggest_subcommand "cron list $1" "")"
        [[ -n "$_hint" ]] && bridge_warn "$_hint"
        bridge_die "지원하지 않는 list 옵션입니다: $1"
        ;;
    esac
  done

  bridge_cron_python "${py_args[@]}"
}

bridge_cron_validate_shell_run_config() {
  local run_as_agent="$1"
  local script_path="${2:-}"

  [[ -n "$run_as_agent" ]] || bridge_die "--run-as-agent is required for --kind shell"
  bridge_load_roster
  bridge_require_agent "$run_as_agent"
  # Issue #1426: `--kind shell` runs a script under a dedicated isolated OS
  # UID, which only exists on Linux hosts with linux-user isolation (iso v2)
  # active. On macOS / non-iso installs there is no per-agent UID to drop to,
  # so this kind is structurally unavailable. Point the author at the
  # supported scheduled-shell paths instead of leaving them at a dead end
  # after they have already written and tested a script.
  bridge_agent_linux_user_isolation_effective "$run_as_agent" \
    || bridge_die "$(printf '%s\n%s\n%s\n%s' \
        "--kind shell requires a linux-user isolated agent (iso v2); '$run_as_agent' is not one." \
        "iso v2 is Linux-only — on macOS / non-iso installs --kind shell is unavailable." \
        "To run a script on a schedule without iso, use one of:" \
        "  1) OS crontab (recommended; bypasses claude/codex entirely), or 2) a --kind text cron whose payload runs 'bash <script>' against a non-Claude (codex) agent. See OPERATIONS.md \"Scheduled shell scripts without iso v2\".")"

  local os_user
  os_user="$(bridge_agent_os_user "$run_as_agent")"
  [[ -n "$os_user" ]] || bridge_die "--run-as-agent has no os_user: $run_as_agent"
  if [[ "$run_as_agent" =~ ^[0-9]+$ || "$os_user" =~ ^[0-9]+$ ]]; then
    bridge_die "--run-as-agent must be an agent id, not a numeric UID/user"
  fi

  [[ -n "$script_path" ]] || bridge_die "--script is required for --kind shell"
  local resolved_script="$script_path"
  case "$resolved_script" in
    '$BRIDGE_HOME'|'$BRIDGE_HOME'/*)
      resolved_script="${BRIDGE_HOME}${resolved_script#'$BRIDGE_HOME'}"
      ;;
    *'$'*)
      bridge_die "--script contains an unresolved environment variable: $script_path"
      ;;
  esac
  [[ "$resolved_script" = /* ]] || bridge_die "--script must resolve to an absolute path: $script_path"
  [[ -f "$resolved_script" && -x "$resolved_script" ]] || bridge_die "--script must be an executable file: $resolved_script"

  local owner_uid run_uid controller_uid mode_bits
  owner_uid="$(stat -c '%u' "$resolved_script" 2>/dev/null || true)"
  mode_bits="$(stat -c '%a' "$resolved_script" 2>/dev/null || true)"
  run_uid="$(id -u "$os_user" 2>/dev/null || true)"
  controller_uid="$(id -u)"
  [[ -n "$owner_uid" && -n "$run_uid" ]] || bridge_die "could not resolve --script owner or --run-as-agent uid"
  if [[ "$owner_uid" != "$controller_uid" && "$owner_uid" != "$run_uid" ]]; then
    bridge_die "--script owner must be controller uid or run-as uid: $resolved_script"
  fi
  if (( (8#$mode_bits) & 0022 )); then
    bridge_die "--script must not be group/other writable: $resolved_script"
  fi
}

run_create() {
  local py_args=(
    native-create
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
  )
  local kind="text"
  local run_as_agent=""
  local script_path=""
  # Issue #1359 — collect the args we need to re-emit into a staging
  # payload when the caller is an iso v2 UID. Direct fields are the
  # canonical native-create surface; --actor / --kind=shell / shell
  # options never go through staging (kind=text only, tactical scope).
  local opt_agent=""
  local opt_schedule=""
  local opt_at=""
  local opt_title=""
  local opt_payload=""
  local opt_payload_file=""
  local opt_tz=""
  local opt_disabled=0
  local opt_delete_after_run=0
  # Sentinel so the staging serializer can distinguish "operator did
  # not pass --payload" from "operator passed empty string". JSON null
  # tells the helper to skip emitting the flag entirely.
  local opt_payload_set=0
  local opt_payload_file_set=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--schedule|--at|--title|--payload|--payload-file|--tz|--actor|--kind|--script|--script-arg|--script-env|--run-as-agent|--timeout|--output-cap)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --kind) kind="$2" ;;
          --run-as-agent) run_as_agent="$2" ;;
          --script) script_path="$2" ;;
          --agent) opt_agent="$2" ;;
          --schedule) opt_schedule="$2" ;;
          --at) opt_at="$2" ;;
          --title) opt_title="$2" ;;
          --payload) opt_payload="$2"; opt_payload_set=1 ;;
          --payload-file) opt_payload_file="$2"; opt_payload_file_set=1 ;;
          --tz) opt_tz="$2" ;;
        esac
        py_args+=("$1" "$2")
        shift 2
        ;;
      --disabled|--delete-after-run)
        case "$1" in
          --disabled) opt_disabled=1 ;;
          --delete-after-run) opt_delete_after_run=1 ;;
        esac
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 create 옵션입니다: $1"
        ;;
    esac
  done

  # Issue #1359 tactical staging delegation. When the caller is an iso
  # v2 UID (`BRIDGE_AGENT_ID` set + current uid != controller uid +
  # cron/jobs.json not writable by the iso UID), route through the
  # `state/cron-staging/<uuid>.json` file delegation path so the
  # controller daemon applies the mutation on the iso UID's behalf.
  # Shell-kind cron is explicitly out of tactical scope — the runner
  # validation matrix needs controller-side script ownership that the
  # staging path cannot prove from a forged payload.
  #
  # codex r1 BLOCKING #3: cross-agent mutation from inside an iso UID
  # must be REJECTED, not silently downgraded to the direct write path.
  # The previous shape returned `should_stage=1` when `--agent` did
  # not match `BRIDGE_AGENT_ID` and then fell through to the direct
  # bridge-cron.py invocation; on hosts where jobs.json was writable
  # by the iso UID (e.g. opened by a misconfigured operator), this
  # bypassed the "iso agent may mutate only its own cron" boundary.
  #
  # codex r2 review escalation: the reject must fire on iso-IDENTITY
  # context (BRIDGE_AGENT_ID set + iso v2 active + non-controller UID),
  # NOT only when staging is the chosen path. The previous shape
  # gated the bridge_die on `_bridge_cron_create_iso_context_active`,
  # which itself returns 1 when jobs.json is writable — so a writable
  # jobs.json (the very misconfigured-operator case the comment names)
  # short-circuited the guard and the direct write went through.
  # Split: identity check fires the guard first, then the staging
  # predicate decides stage vs direct for same-agent requests.
  #
  # codex r2 self-review BLOCKING: the previous shape gated the
  # bridge_die on `kind == text`. A `--kind shell` request from inside
  # an iso UID with writable jobs.json would skip the guard entirely
  # and fall through to `bridge_cron_python` which accepts shell
  # payloads and writes the job for `args.agent`. The reject must fire
  # on identity context regardless of kind — shell-kind staging
  # delegation is still out of scope (the runner needs controller-side
  # script ownership the staging path cannot prove), but the boundary
  # "iso agents may only mutate own cron" applies to ALL kinds. After
  # this guard, only same-agent or non-iso-identity requests proceed,
  # and shell-kind same-agent requests still hit the direct write path
  # (which is correct: a same-agent shell cron is the iso UID writing
  # its own job, no boundary violation).
  #
  # NOTE on ordering: this guard MUST fire BEFORE
  # `bridge_cron_validate_shell_run_config` below. The shell-kind
  # validator rejects on missing `--run-as-agent` / `--script` with a
  # different bridge_die that would mask the identity reject — and an
  # attacker can satisfy both by passing `--kind shell --script foo
  # --run-as-agent <peer>`. The identity reject must be the first thing
  # an iso-context shell with cross-agent intent hits, regardless of
  # what other args it carries.
  if _bridge_cron_create_iso_identity_active; then
    local effective_agent="${opt_agent:-${BRIDGE_AGENT_ID:-}}"
    if [[ -n "$effective_agent" && "$effective_agent" != "${BRIDGE_AGENT_ID:-}" ]]; then
      bridge_die "cron mutation refused: requested agent ${effective_agent} does not match BRIDGE_AGENT_ID ${BRIDGE_AGENT_ID:-<unset>} (iso agents may only mutate own cron)"
    fi
  fi

  if [[ "$kind" == "shell" ]]; then
    bridge_cron_validate_shell_run_config "$run_as_agent" "$script_path"
  fi

  if [[ "$kind" == "text" ]]; then
    if _bridge_cron_create_iso_context_active; then
      _bridge_cron_create_via_staging \
        "$opt_agent" \
        "$opt_schedule" \
        "$opt_at" \
        "$opt_title" \
        "$opt_tz" \
        "$opt_payload_set" \
        "$opt_payload" \
        "$opt_payload_file_set" \
        "$opt_payload_file" \
        "$opt_disabled" \
        "$opt_delete_after_run"
      return $?
    fi
  fi

  bridge_cron_python "${py_args[@]}"
}

# Issue #1359 codex r2 review escalation — narrow identity predicate
# used by the cross-agent reject guard.
#
# Returns 0 when this shell is running with an iso-agent IDENTITY
# (BRIDGE_AGENT_ID set, iso v2 layout active), regardless of whether
# jobs.json happens to be writable by the current UID. The cross-
# agent reject in `run_create` must fire whenever this is true, so a
# misconfigured-writable jobs.json cannot bypass the "iso agents may
# only mutate own cron" boundary. Controller shells should never have
# BRIDGE_AGENT_ID set in the iso-v2 deployment — that is itself the
# identity marker we use.
_bridge_cron_create_iso_identity_active() {
  local agent_id="${BRIDGE_AGENT_ID:-}"
  [[ -n "$agent_id" ]] || return 1
  if ! declare -F bridge_isolation_v2_active >/dev/null 2>&1; then
    return 1
  fi
  bridge_isolation_v2_active || return 1
  return 0
}

# Issue #1359 — predicate that decides whether we are currently running
# inside an iso v2 agent UID context that needs to delegate cron
# mutations through the staging path.
#
# codex r1 BLOCKING #3 (r2): the previous predicate bundled the
# `requested_agent == BRIDGE_AGENT_ID` check into the should-stage
# decision and silently returned "no, direct write" for cross-agent
# requests. That allowed `bash bridge-cron.sh create --agent <peer>`
# from inside an iso UID to fall through to the direct write path on
# hosts where jobs.json happened to be writable by the iso UID. The
# split-up shape now is:
#
#   - `_bridge_cron_create_iso_context_active` (this function):
#       returns 0 (yes) when ALL hold — BRIDGE_AGENT_ID is set, iso v2
#       layout is active, current UID is NOT the controller UID, and
#       jobs.json is not writable directly. Used as the gating
#       condition for "delegate to daemon".
#
#   - The caller in `run_create` decides what to do with the cross-
#       agent case BEFORE we get here: a mismatched `--agent` raises a
#       `bridge_die` rather than falling through to the direct write
#       path.
#
# Returns 0 when iso UID context is active; 1 otherwise (including the
# operator-on-controller case and the iso-UID-with-writable-jobs.json
# defense-in-depth case).
_bridge_cron_create_iso_context_active() {
  local agent_id="${BRIDGE_AGENT_ID:-}"

  [[ -n "$agent_id" ]] || return 1
  # Without iso v2 layout, the staging dir cannot have iso-writable
  # mode, so the direct path is the only one that works.
  if ! declare -F bridge_isolation_v2_active >/dev/null 2>&1; then
    return 1
  fi
  bridge_isolation_v2_active || return 1

  local cur_uid jobs_file
  cur_uid="$(id -u 2>/dev/null || printf '')"
  [[ -n "$cur_uid" ]] || return 1
  jobs_file="${BRIDGE_NATIVE_CRON_JOBS_FILE:-}"

  if [[ -n "$jobs_file" && -e "$jobs_file" ]]; then
    # If we can already write the file directly, no need to stage.
    if [[ -w "$jobs_file" ]]; then
      return 1
    fi
    return 0
  fi

  # jobs.json absent → compare current UID to the controller UID. We
  # cannot know the controller UID with certainty in this branch
  # (no marker yet), so we fall back to "differ from the parent
  # directory owner if reachable". Best-effort: when the parent dir
  # is missing OR matches our UID, treat as not-iso and skip staging.
  local cron_home_dir cron_home_owner
  cron_home_dir="${BRIDGE_CRON_HOME_DIR:-}"
  if [[ -n "$cron_home_dir" && -d "$cron_home_dir" ]]; then
    cron_home_owner="$(stat -c '%u' "$cron_home_dir" 2>/dev/null || stat -f '%u' "$cron_home_dir" 2>/dev/null || true)"
    if [[ -n "$cron_home_owner" && "$cron_home_owner" != "$cur_uid" ]]; then
      return 0
    fi
  fi
  return 1
}

# Issue #1359 — back-compat shim. The r1 codepath called
# `_bridge_cron_create_should_stage` with the requested agent and
# expected a single "yes/no stage" verdict. The r2 refactor split the
# iso-context detection from the cross-agent reject — this shim is
# preserved so any external caller (out-of-tree script, future-merged
# branch) gets a verdict that PRESERVES the cross-agent security
# boundary rather than falling through to the direct write path.
#
# codex r2 review escalation: the previous shim returned 1 on cross-
# agent mismatch which lets legacy callers do `if
# _bridge_cron_create_should_stage; then stage; else direct; fi` and
# silently downgrade a cross-agent request to a direct write. That
# leaks the same boundary the new call site closes. The shim now
# bridge_die's on cross-agent identity context — any caller hitting
# this path gets the same explicit reject as the new call site.
_bridge_cron_create_should_stage() {
  local requested_agent="${1:-}"
  local agent_id="${BRIDGE_AGENT_ID:-}"

  # Defense-in-depth: even outside the staging-routing branch, if we
  # are running with an iso-agent identity and the requested agent
  # does not match, refuse rather than letting the caller fall
  # through to a direct write.
  if _bridge_cron_create_iso_identity_active; then
    if [[ -n "$requested_agent" && "$requested_agent" != "$agent_id" ]]; then
      bridge_die "cron mutation refused: requested agent ${requested_agent} does not match BRIDGE_AGENT_ID ${agent_id:-<unset>} (iso agents may only mutate own cron)"
    fi
  fi
  _bridge_cron_create_iso_context_active || return 1
  return 0
}

# Issue #1359 — staging delegation writer + poller. Composes the JSON
# payload from the parsed --agent / --schedule / --title / --payload-*
# / --tz / --disabled / --delete-after-run options, writes a staging
# file via the staging.py helper, then polls for the daemon-written
# result.json sibling. Prints native-create's success line (or surfaces
# the daemon's error to stderr) so existing operator workflows keep
# parsing the cron id from stdout.
_bridge_cron_create_via_staging() {
  local agent="$1"
  local schedule="$2"
  local at="$3"
  local title="$4"
  local tz="$5"
  local payload_set="$6"
  local payload="$7"
  local payload_file_set="$8"
  local payload_file="$9"
  local disabled="${10}"
  local delete_after_run="${11}"

  bridge_require_python
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi

  local staging_dir="${BRIDGE_CRON_STAGING_DIR:-}"
  [[ -n "$staging_dir" ]] || bridge_die "BRIDGE_CRON_STAGING_DIR unset; cannot route iso cron create"

  # Build the canonical payload JSON via python (avoids bash quoting
  # gymnastics around --payload bodies that contain newlines, quotes,
  # or json metacharacters). Stdin to the python child is a small env
  # dump with the parsed values — no heredoc-stdin to subprocess
  # (footgun #11) since the python builds the JSON and prints it to
  # stdout for capture below.
  local payload_json=""
  local actor_uid
  actor_uid="$(id -u 2>/dev/null || printf '0')"
  # shellcheck disable=SC2155
  # #1387: initialize to "" so the cleanup trap is robust under `set -u`
  # regardless of which path set it (the trap also guards with `:-` in
  # case it fires before the mktemp assignment completes).
  local _payload_json_tmp=""
  trap 'rm -f "${_payload_json_tmp:-}"' RETURN
  _payload_json_tmp="$(mktemp -t agb-cron-staging-payload.XXXXXX)" || \
    bridge_die "cannot mktemp cron-staging payload buffer"

  AGB_STAGE_AGENT="$agent" \
  AGB_STAGE_SCHEDULE="$schedule" \
  AGB_STAGE_AT="$at" \
  AGB_STAGE_TITLE="$title" \
  AGB_STAGE_TZ="$tz" \
  AGB_STAGE_PAYLOAD_SET="$payload_set" \
  AGB_STAGE_PAYLOAD="$payload" \
  AGB_STAGE_PAYLOAD_FILE_SET="$payload_file_set" \
  AGB_STAGE_PAYLOAD_FILE="$payload_file" \
  AGB_STAGE_DISABLED="$disabled" \
  AGB_STAGE_DELETE_AFTER_RUN="$delete_after_run" \
  AGB_STAGE_ACTOR_AGENT="${BRIDGE_AGENT_ID:-}" \
  AGB_STAGE_ACTOR_UID="$actor_uid" \
  python3 - "$_payload_json_tmp" <<'PY'
import json
import os
import sys

out_path = sys.argv[1]
payload = {
    "schema_version": 1,
    "action": "create",
    "actor_agent": os.environ.get("AGB_STAGE_ACTOR_AGENT", ""),
    "actor_uid": int(os.environ.get("AGB_STAGE_ACTOR_UID", "0") or 0),
    "agent": os.environ.get("AGB_STAGE_AGENT", ""),
    "title": os.environ.get("AGB_STAGE_TITLE", ""),
    "tz": os.environ.get("AGB_STAGE_TZ", "") or None,
    "kind": "text",
    "disabled": os.environ.get("AGB_STAGE_DISABLED", "0") == "1",
    "delete_after_run": os.environ.get("AGB_STAGE_DELETE_AFTER_RUN", "0") == "1",
}
sched = os.environ.get("AGB_STAGE_SCHEDULE", "")
at = os.environ.get("AGB_STAGE_AT", "")
payload["schedule"] = sched if sched else None
payload["at"] = at if at else None
if os.environ.get("AGB_STAGE_PAYLOAD_SET", "0") == "1":
    payload["payload"] = os.environ.get("AGB_STAGE_PAYLOAD", "")
else:
    payload["payload"] = None
if os.environ.get("AGB_STAGE_PAYLOAD_FILE_SET", "0") == "1":
    payload["payload_file"] = os.environ.get("AGB_STAGE_PAYLOAD_FILE", "")
else:
    payload["payload_file"] = None
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
PY

  # shellcheck disable=SC2155
  local payload_json_body
  payload_json_body="$(cat "$_payload_json_tmp")"

  local actor_agent="${BRIDGE_AGENT_ID:-}"
  [[ -n "$actor_agent" ]] || bridge_die "BRIDGE_AGENT_ID unset; cannot route iso cron create"

  # #1379: resolve the shared cross-class group name the staging file
  # must carry (`ab-agent-<actor_agent>`, hash-truncated for long agent
  # names) so the controller/daemon can read it — the iso UID's own
  # `mkdir`+write would otherwise leave the file in the user-private
  # group `agent-bridge-<a>`, which the controller is not a member of.
  # Resolving the (possibly hash-truncated) name on the bash side is
  # authoritative; staging.py also has a self-contained fallback chain,
  # so this is best-effort — an empty value just defers to that chain.
  local staging_file_group=""
  if command -v bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then
    staging_file_group="$(bridge_isolation_v2_agent_group_name "$actor_agent" 2>/dev/null || printf '')"
  fi

  local request_uuid
  if ! request_uuid="$(AGB_STAGE_FILE_GROUP="$staging_file_group" \
        python3 "$BRIDGE_SCRIPT_DIR/lib/cron-helpers/staging.py" \
        write-request "$staging_dir" "$actor_agent" "$payload_json_body")"; then
    bridge_die "cron-staging write-request failed (BRIDGE_CRON_STAGING_DIR=$staging_dir)"
  fi
  request_uuid="${request_uuid%%$'\n'*}"
  [[ -n "$request_uuid" ]] || bridge_die "cron-staging write-request returned empty uuid"

  # Stderr advisory so the operator sees the staging mode. Stdout
  # remains the cron-id line the existing operator workflow expects.
  printf '[cron-staging] iso UID delegate: queued staging request %s; awaiting daemon apply (timeout %ss)\n' \
    "$request_uuid" "$BRIDGE_CRON_STAGING_TIMEOUT_SECONDS" >&2

  # Poll the result.json sibling. Bound by
  # BRIDGE_CRON_STAGING_TIMEOUT_SECONDS so a wedged / down daemon does
  # not hang the operator's terminal.
  local elapsed=0
  local interval="${BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS:-1}"
  local timeout="${BRIDGE_CRON_STAGING_TIMEOUT_SECONDS:-30}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=30
  local result_path="$staging_dir/$actor_agent/${request_uuid}.result.json"
  while (( elapsed < timeout )); do
    if [[ -f "$result_path" ]]; then
      break
    fi
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done

  if [[ ! -f "$result_path" ]]; then
    printf 'error: cron-staging timed out after %ss waiting for daemon to apply %s\n' \
      "$timeout" "$request_uuid" >&2
    printf '       (daemon may be down; staging file: %s/%s/%s.json)\n' \
      "$staging_dir" "$actor_agent" "$request_uuid" >&2
    return 4
  fi

  # Parse the result.json status / cron_id / error.
  local result_status="" result_cron_id="" result_error=""
  # shellcheck disable=SC2034
  local _parsed
  _parsed="$(python3 - "$result_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print("status=" + (data.get("status") or ""))
print("cron_id=" + (data.get("cron_id") or ""))
print("error=" + (data.get("error") or ""))
PY
)" || bridge_die "cron-staging cannot parse $result_path"

  while IFS= read -r _line; do
    case "$_line" in
      status=*) result_status="${_line#status=}" ;;
      cron_id=*) result_cron_id="${_line#cron_id=}" ;;
      error=*) result_error="${_line#error=}" ;;
    esac
  done <<<"$_parsed"

  if [[ "$result_status" == "ok" ]]; then
    # Match native-create's stdout shape so existing parsers
    # (e.g. cron-mutation-audit smoke) continue to work.
    printf 'created native cron job %s for %s\n' "$result_cron_id" "$agent"
    return 0
  fi
  printf 'error: cron-staging apply failed: %s\n' "${result_error:-unknown_error}" >&2
  return 5
}

run_update() {
  local job_ref="${1:-}"
  local py_args=(
    native-update
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
  )
  local kind=""
  local run_as_agent=""
  local script_path=""
  local shell_option_seen=0

  shift || true
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") update <job-id> [--agent <bridge-agent>] [--schedule <cron-expr>|--at <iso-datetime>] [--title <title>] [--payload <text>|--payload-file <path>] [--tz <iana-tz>] [--enable|--disable] [--delete-after-run|--keep-after-run]"
  py_args+=("$job_ref")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--schedule|--at|--title|--payload|--payload-file|--tz|--actor|--kind|--script|--script-arg|--script-env|--run-as-agent|--timeout|--output-cap)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --kind) kind="$2" ;;
          --run-as-agent) run_as_agent="$2" ;;
          --script) script_path="$2" ;;
        esac
        case "$1" in
          --kind|--script|--script-arg|--script-env|--run-as-agent|--timeout|--output-cap)
            shell_option_seen=1
            ;;
        esac
        py_args+=("$1" "$2")
        shift 2
        ;;
      --enable|--disable|--delete-after-run|--keep-after-run|--allow-kind-transition)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 update 옵션입니다: $1"
        ;;
    esac
  done

  local existing_shell_payload=""
  local existing_payload_kind=""
  local existing_script_path=""
  local existing_run_as_agent=""
  existing_shell_payload="$(bridge_cron_python show --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE" --format shell "$job_ref" 2>/dev/null || true)"
  if [[ -n "$existing_shell_payload" ]]; then
    local CRON_JOB_PAYLOAD_KIND=""
    local CRON_JOB_PAYLOAD_SHELL_SCRIPT=""
    local CRON_JOB_EXECUTION_RUN_AS_AGENT=""
    # shellcheck disable=SC1090
    source <(printf '%s\n' "$existing_shell_payload")
    existing_payload_kind="$CRON_JOB_PAYLOAD_KIND"
    existing_script_path="$CRON_JOB_PAYLOAD_SHELL_SCRIPT"
    existing_run_as_agent="$CRON_JOB_EXECUTION_RUN_AS_AGENT"
  fi

  if [[ "$existing_payload_kind" == "shell" || "$kind" == "shell" || $shell_option_seen -eq 1 ]]; then
    bridge_cron_validate_shell_run_config "${run_as_agent:-$existing_run_as_agent}" "${script_path:-$existing_script_path}" "update"
  fi

  bridge_cron_python "${py_args[@]}"
}

run_delete() {
  local job_ref="${1:-}"
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") delete <job-id>"
  shift || true
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 delete 옵션입니다: $1"
  bridge_cron_python native-delete --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE" "$job_ref"
}

run_rebalance_memory_daily() {
  local jobs_file="$BRIDGE_NATIVE_CRON_JOBS_FILE"
  local py_args=(native-rebalance-memory-daily)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs-file|--schedule|--tz|--actor)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        if [[ "$1" == "--jobs-file" ]]; then
          jobs_file="$2"
        else
          py_args+=("$1" "$2")
        fi
        shift 2
        ;;
      --dry-run|--json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 rebalance-memory-daily 옵션입니다: $1"
        ;;
    esac
  done

  py_args+=(--jobs-file "$jobs_file")
  bridge_cron_python "${py_args[@]}"
}

# Issue #541 PR-A — operator-driven migration of memory-daily payloads to
# the canonical jsonl-aware body. Mirrors the cleanup-prune surface
# (jobs.json.bak-<timestamp> backup, --dry-run, --json).
run_migrate_payloads() {
  local jobs_file="$BRIDGE_NATIVE_CRON_JOBS_FILE"
  local py_args=(migrate-payloads)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs-file)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        jobs_file="$2"
        shift 2
        ;;
      --jsonl-aware|--dry-run|--json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 migrate-payloads 옵션입니다: $1"
        ;;
    esac
  done

  py_args+=(--jobs-file "$jobs_file")
  bridge_cron_python "${py_args[@]}"
}

write_materialized_payload() {
  local payload_file="$1"
  local slot="$2"
  local source_file="$3"
  local target="$4"
  local delivery_mode="$5"
  local channel_delivery_mode="${6:-}"
  local channel_delivery_channel="${7:-}"
  local channel_delivery_target="${8:-}"
  local allow_channel_delivery="${9:-0}"

  mkdir -p "$(dirname "$payload_file")"
  {
    printf '# [cron] %s\n\n' "$CRON_JOB_NAME"
    printf -- '- slot: %s\n' "$slot"
    printf -- '- source_agent: %s\n' "$CRON_JOB_AGENT"
    printf -- '- target_agent: %s\n' "$target"
    printf -- '- delivery_mode: %s\n' "$delivery_mode"
    printf -- '- channel_delivery_mode: %s\n' "$channel_delivery_mode"
    printf -- '- channel_delivery_channel: %s\n' "$channel_delivery_channel"
    printf -- '- channel_delivery_target: %s\n' "$channel_delivery_target"
    printf -- '- allow_channel_delivery: %s\n' "$allow_channel_delivery"
    printf -- '- family: %s\n' "$CRON_JOB_FAMILY"
    printf -- '- schedule: %s\n' "$CRON_JOB_SCHEDULE_TEXT"
    printf -- '- source_file: %s\n' "$source_file"
    printf -- '- payload_kind: %s\n' "$CRON_JOB_PAYLOAD_KIND"
    printf '\n## Original Payload\n\n'
    printf '%s\n' "$CRON_JOB_PAYLOAD_TEXT"
  } >"$payload_file"
}

write_dispatch_body() {
  local body_file="$1"
  local slot="$2"
  local run_id="$3"
  local payload_file="$4"
  local request_file="$5"
  local result_file="$6"
  local status_file="$7"
  local target="$8"
  local target_engine="$9"
  local delivery_mode="${10}"
  local channel_delivery_mode="${11:-}"
  local channel_delivery_channel="${12:-}"
  local channel_delivery_target="${13:-}"
  local allow_channel_delivery="${14:-0}"

  mkdir -p "$(dirname "$body_file")"
  {
    printf '# [cron-dispatch] %s\n\n' "$CRON_JOB_NAME"
    printf -- '- run_id: %s\n' "$run_id"
    printf -- '- slot: %s\n' "$slot"
    printf -- '- target_agent: %s\n' "$target"
    printf -- '- target_engine: %s\n' "$target_engine"
    printf -- '- delivery_mode: %s\n' "$delivery_mode"
    printf -- '- channel_delivery_mode: %s\n' "$channel_delivery_mode"
    printf -- '- channel_delivery_channel: %s\n' "$channel_delivery_channel"
    printf -- '- channel_delivery_target: %s\n' "$channel_delivery_target"
    printf -- '- allow_channel_delivery: %s\n' "$allow_channel_delivery"
    printf -- '- source_agent: %s\n' "$CRON_JOB_AGENT"
    printf -- '- family: %s\n' "$CRON_JOB_FAMILY"
    printf -- '- payload_file: %s\n' "$payload_file"
    printf -- '- request_file: %s\n' "$request_file"
    printf -- '- result_file: %s\n' "$result_file"
    printf -- '- status_file: %s\n' "$status_file"
    printf '\n## Instruction\n\n'
    printf 'This dispatch task is owned by the bridge daemon.\n\n'
    printf '1. The daemon claims this task and runs `agent-bridge cron run-subagent %s`\n' "$run_id"
    printf '2. The disposable child writes structured result artifacts under `state/cron/runs/%s/`\n' "$run_id"
    printf '3. The daemon closes this dispatch task when the child finishes\n'
    printf '4. If human follow-up is still needed, the daemon creates a separate `[cron-followup]` queue task\n'
    if [[ "$delivery_mode" == "fallback" ]]; then
      printf '5. This run was routed through the cron fallback agent because `%s` is not a registered cron delivery role\n' "$CRON_JOB_AGENT"
    fi
  } >"$body_file"
}

build_shell_env_snapshot_json() {
  local run_as_agent="$1"
  local os_user="$2"
  local run_home="$3"
  local agent_env_file="$4"

  (
    set -a
    if [[ -f "$agent_env_file" ]]; then
      # shellcheck source=/dev/null
      source "$agent_env_file"
    fi
    set +a
    export HOME="$run_home"
    export USER="$os_user"
    export LOGNAME="$os_user"
    export BRIDGE_AGENT_ID="$run_as_agent"
    export BRIDGE_AGENT_NAME="$run_as_agent"
    export BRIDGE_AGENT_ENV_FILE="$agent_env_file"
    export BRIDGE_CONTROLLER_UID="${BRIDGE_CONTROLLER_UID:-$(id -u)}"
    export BRIDGE_GATEWAY_PROXY=1
    bridge_require_python
    python3 - <<'PY'
import json
import os

exact = {
    "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL",
}
payload = {}
for key, value in os.environ.items():
    if key in exact or key.startswith("BRIDGE_"):
        payload[key] = value
print(json.dumps(payload, ensure_ascii=True, sort_keys=True))
PY
  )
}

run_enqueue() {
  local job_ref=""
  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  local slot=""
  local target=""
  local actor=""
  local priority="normal"
  local dry_run=0
  local title=""
  local body_file=""
  local manifest_file=""
  local manifest_rel=""
  local body_rel=""
  local request_file=""
  local request_rel=""
  local result_file=""
  local result_rel=""
  local status_file=""
  local status_rel=""
  local payload_file=""
  local payload_rel=""
  local stdout_log=""
  local stderr_log=""
  local run_id=""
  local target_engine=""
  local target_workdir=""
  local create_output=""
  local task_id=""
  local created_at=""
  local shell_payload=""
  local delivery_mode="resolved"
  local fallback_agent=""
  local job_delivery_mode=""
  local job_delivery_channel=""
  local job_delivery_target=""
  local allow_channel_delivery="0"
  local disposable_needs_channels="0"
  local disable_mcp="0"
  local target_channels=""
  local target_discord_state_dir=""
  local target_telegram_state_dir=""
  local shell_run_as_agent=""
  local shell_os_user=""
  local shell_uid=""
  local shell_gid=""
  local shell_home=""
  local shell_agent_env_file=""
  local shell_env_snapshot_json="{}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot|--target|--from|--priority|--jobs-file)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --jobs-file) jobs_file="$2" ;;
          --slot) slot="$2" ;;
          --target) target="$2" ;;
          --from) actor="$2" ;;
          --priority) priority="$2" ;;
        esac
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$job_ref" ]]; then
          job_ref="$1"
          shift
          continue
        fi
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") enqueue <job-name-or-id> [--jobs-file <path>] [--slot <slot-key>] [--target <bridge-agent>] [--from <actor>] [--priority normal|high] [--dry-run]"
  bridge_require_cron_source_jobs "$jobs_file"

  case "$priority" in
    normal|high) ;;
    *)
      bridge_die "--priority는 normal 또는 high만 지원합니다."
      ;;
  esac

  [[ -f "$jobs_file" ]] || bridge_die "cron jobs 파일이 없습니다: $jobs_file"
  bridge_load_roster

  local CRON_JOB_ID=""
  local CRON_JOB_NAME=""
  local CRON_JOB_AGENT=""
  local CRON_JOB_FAMILY=""
  local CRON_JOB_KIND=""
  local CRON_JOB_ENABLED=""
  local CRON_JOB_SCHEDULE_TEXT=""
  local CRON_JOB_NEXT_RUN_AT=""
  local CRON_JOB_PAYLOAD_KIND=""
  local CRON_JOB_PAYLOAD_TEXT=""
  local CRON_JOB_PAYLOAD_SHELL_SCRIPT=""
  local CRON_JOB_PAYLOAD_SHELL_ARGS="[]"
  local CRON_JOB_PAYLOAD_SHELL_ENV="{}"
  local CRON_JOB_PAYLOAD_SHELL_TIMEOUT_SECONDS=""
  local CRON_JOB_PAYLOAD_SHELL_OUTPUT_CAP_BYTES=""
  local CRON_JOB_EXECUTION_RUN_AS_AGENT=""

  shell_payload="$(bridge_cron_python show --jobs-file "$jobs_file" --format shell "$job_ref")" || exit $?
  # shellcheck disable=SC1090
  source <(printf '%s\n' "$shell_payload")

  [[ "$CRON_JOB_ENABLED" == "1" ]] || bridge_die "비활성 cron job은 enqueue할 수 없습니다: $CRON_JOB_NAME"
  case "$CRON_JOB_KIND" in
    recurring|one-shot) ;;
    *)
      bridge_die "지원하지 않는 cron job kind 입니다: $CRON_JOB_NAME ($CRON_JOB_KIND)"
      ;;
  esac

  if [[ -z "$slot" ]]; then
    slot="$(bridge_cron_slot_for_job "$CRON_JOB_KIND" "$CRON_JOB_FAMILY" "$CRON_JOB_NEXT_RUN_AT")"
  fi

  if [[ -n "$target" ]]; then
    bridge_require_cron_delivery_target "$target"
    delivery_mode="explicit"
  else
    target="$(bridge_resolve_cron_target "$CRON_JOB_AGENT" || true)"
    if [[ -n "$target" ]]; then
      delivery_mode="mapped"
    else
      fallback_agent="$(bridge_cron_fallback_agent || true)"
      if [[ -z "$fallback_agent" ]]; then
        bridge_die "cron target을 찾지 못했습니다: $CRON_JOB_AGENT (등록된 cron delivery role 매핑이나 BRIDGE_CRON_FALLBACK_AGENT/admin role이 필요합니다)"
      fi
      target="$fallback_agent"
      delivery_mode="fallback"
    fi
  fi

  actor="${actor:-cron:$CRON_JOB_NAME}"
  title="[cron-dispatch] $CRON_JOB_NAME ($slot)"

  # Issue #1327 (v0.15.0-beta5-2 Lane μ M4): honor the operator's
  # manual-stop intent at the dispatch site. The daemon-side
  # `bridge_daemon_cron_dispatch_wake` already refuses to wake a
  # manually-stopped static agent for an existing queued cron-dispatch
  # row, but the enqueue path itself still creates the queue task —
  # which then sits in the queue until the operator clears the
  # manual-stop flag (or worse, an autostart later picks it up after
  # the wake-side gate cleared). Block at enqueue so the row never
  # exists; the wake-side gate stays as a defense-in-depth
  # check for the auto-stop / agent-restart race (edge case 1).
  #
  # Distinguishes manual-stop (operator intent, honor here) from any
  # other "agent currently down" condition (autostart backoff,
  # broken-launch quarantine, daemon-side throttle, etc.). Those
  # cases stay handled by the wake-side path and allow re-attempt;
  # only manual-stop is honored at enqueue (edge case 2). The check
  # is gated on `bridge_agent_manual_stop_active` being declared so a
  # smoke harness that loads `bridge-cron.sh` without `bridge-state.sh`
  # (rare path — full upgrade flow always sources both) does not
  # surface as an undefined-function error; in that case the gate is
  # treated as inactive and the row is enqueued normally.
  if declare -F bridge_agent_manual_stop_active >/dev/null 2>&1 \
      && bridge_agent_manual_stop_active "$target" 2>/dev/null; then
    if declare -F bridge_audit_log >/dev/null 2>&1; then
      bridge_audit_log cron cron_dispatch_skipped "$target" \
        --detail job_name="$CRON_JOB_NAME" \
        --detail job_id="$CRON_JOB_ID" \
        --detail family="$CRON_JOB_FAMILY" \
        --detail slot="$slot" \
        --detail reason=manual_stop 2>/dev/null || true
    fi
    bridge_warn "cron-dispatch skipped ${target} (reason=manual_stop, job=${CRON_JOB_NAME} slot=${slot})"
    printf 'status: skipped\n'
    printf 'reason: manual_stop\n'
    printf 'target: %s\n' "$target"
    printf 'job_name: %s\n' "$CRON_JOB_NAME"
    printf 'slot: %s\n' "$slot"
    return 0
  fi

  run_id="$(bridge_cron_run_id "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  request_file="$(bridge_cron_request_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  result_file="$(bridge_cron_result_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  status_file="$(bridge_cron_status_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  stdout_log="$(bridge_cron_stdout_log "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  stderr_log="$(bridge_cron_stderr_log "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  payload_file="$(bridge_cron_payload_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  body_file="$(bridge_cron_body_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  manifest_file="$(bridge_cron_manifest_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  target_engine="$(bridge_agent_engine "$target")"
  target_workdir="$(bridge_agent_workdir "$target")"
  target_channels="$(bridge_agent_channels_csv "$target")"
  target_discord_state_dir="$(bridge_agent_discord_state_dir "$target")"
  target_telegram_state_dir="$(bridge_agent_telegram_state_dir "$target")"
  job_delivery_mode="${CRON_JOB_JOB_DELIVERY_MODE:-}"
  job_delivery_channel="${CRON_JOB_JOB_DELIVERY_CHANNEL:-}"
  job_delivery_target="${CRON_JOB_JOB_DELIVERY_TARGET:-}"
  allow_channel_delivery="${CRON_JOB_ALLOW_CHANNEL_DELIVERY:-0}"
  disposable_needs_channels="${CRON_JOB_DISPOSABLE_NEEDS_CHANNELS:-0}"
  disable_mcp="${CRON_JOB_DISABLE_MCP:-0}"
  # PR1.2 / PR1.6 — per-job cron reporting policy override (Sean Q-B
  # 2026-05-02: default | always_main_session | always_silent) and the
  # urgency hint that maps to the inbox task priority. Empty string
  # = use runner-side defaults (default policy, normal priority).
  cron_reporting_policy="${CRON_JOB_CRON_REPORTING_POLICY:-}"
  cron_urgency="${CRON_JOB_CRON_URGENCY:-}"
  shell_run_as_agent=""
  shell_os_user=""
  shell_uid=""
  shell_gid=""
  shell_home=""
  shell_agent_env_file=""
  shell_env_snapshot_json="{}"
  if [[ "$CRON_JOB_PAYLOAD_KIND" == "shell" ]]; then
    shell_run_as_agent="${CRON_JOB_EXECUTION_RUN_AS_AGENT:-}"
    [[ -n "$shell_run_as_agent" ]] || bridge_die "shell cron job is missing execution.runAsAgent: $CRON_JOB_NAME"
    bridge_require_agent "$shell_run_as_agent"
    bridge_agent_linux_user_isolation_effective "$shell_run_as_agent" \
      || bridge_die "shell cron run_as_agent must be linux-user isolated: $shell_run_as_agent"
    shell_os_user="$(bridge_agent_os_user "$shell_run_as_agent")"
    [[ -n "$shell_os_user" ]] || bridge_die "shell cron run_as_agent has no os_user: $shell_run_as_agent"
    [[ ! "$shell_run_as_agent" =~ ^[0-9]+$ && ! "$shell_os_user" =~ ^[0-9]+$ ]] \
      || bridge_die "shell cron run_as_agent must be an agent id, not numeric UID/user"
    shell_uid="$(id -u "$shell_os_user")"
    shell_gid="$(id -g "$shell_os_user")"
    shell_home="$(getent passwd "$shell_os_user" | awk -F: '{print $6}' | head -n1)"
    [[ -n "$shell_home" ]] || shell_home="$(bridge_agent_linux_user_home "$shell_os_user")"
    shell_agent_env_file="$(bridge_agent_linux_env_file "$shell_run_as_agent")"
    if [[ ! -f "$shell_agent_env_file" ]] && command -v bridge_write_linux_agent_env_file >/dev/null 2>&1; then
      bridge_write_linux_agent_env_file "$shell_run_as_agent" "$shell_agent_env_file"
    fi
    shell_env_snapshot_json="$(build_shell_env_snapshot_json "$shell_run_as_agent" "$shell_os_user" "$shell_home" "$shell_agent_env_file")"
  fi
  request_rel="${request_file#$BRIDGE_HOME/}"
  result_rel="${result_file#$BRIDGE_HOME/}"
  status_rel="${status_file#$BRIDGE_HOME/}"
  payload_rel="${payload_file#$BRIDGE_HOME/}"
  body_rel="${body_file#$BRIDGE_HOME/}"
  manifest_rel="${manifest_file#$BRIDGE_HOME/}"

  if [[ -f "$manifest_file" || -f "$request_file" ]]; then
    # Issue #219: pre-queue ordering writes request/manifest with
    # dispatch_task_id=0 before creating the queue task. If queue create (or
    # the subsequent task-id patch) failed on the previous pass, the run_dir
    # is stranded — there is no queue task to claim it. Validate that the
    # existing artifacts carry a positive task_id; if not, treat the run as
    # recoverable and fall through to re-enqueue (artifacts will be
    # overwritten by the same run_id).
    existing_task_id=""
    if [[ -f "$request_file" ]]; then
      existing_task_id="$("${BRIDGE_PYTHON:-python3}" -c 'import json,sys;
try:
  d=json.load(open(sys.argv[1]))
  v=d.get("dispatch_task_id")
  print(int(v) if v is not None else 0)
except Exception:
  print(0)' "$request_file" 2>/dev/null || echo 0)"
    fi
    if [[ -n "$existing_task_id" && "$existing_task_id" != "0" ]]; then
      printf 'status: already_enqueued\n'
      printf 'job: %s\n' "$CRON_JOB_NAME"
      printf 'slot: %s\n' "$slot"
      printf 'target: %s\n' "$target"
      printf 'run_id: %s\n' "$run_id"
      printf 'request_file: %s\n' "$request_rel"
      printf 'manifest: %s\n' "$manifest_rel"
      return 0
    fi
    # Stranded run from a prior failed dispatch. Clean the partial artifacts
    # so the new pass can produce a coherent run_dir.
    printf 'notice: clearing stranded pre-queue artifacts for run_id=%s (dispatch_task_id=0)\n' "$run_id" >&2
    rm -f "$request_file" "$status_file" "$manifest_file"
  fi

  if [[ $dry_run -eq 1 ]]; then
    printf 'status: dry_run\n'
    printf 'job: %s\n' "$CRON_JOB_NAME"
    printf 'family: %s\n' "$CRON_JOB_FAMILY"
    printf 'slot: %s\n' "$slot"
    printf 'target: %s\n' "$target"
    printf 'delivery_mode: %s\n' "$delivery_mode"
    printf 'engine: %s\n' "$target_engine"
    printf 'actor: %s\n' "$actor"
    printf 'priority: %s\n' "$priority"
    printf 'title: %s\n' "$title"
    printf 'run_id: %s\n' "$run_id"
    printf 'body_file: %s\n' "$body_rel"
    printf 'payload_file: %s\n' "$payload_rel"
    printf 'request_file: %s\n' "$request_rel"
    printf 'result_file: %s\n' "$result_rel"
    printf 'status_file: %s\n' "$status_rel"
    printf 'manifest: %s\n' "$manifest_rel"
    return 0
  fi

  write_materialized_payload "$payload_file" "$slot" "$jobs_file" "$target" "$delivery_mode" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery"
  write_dispatch_body "$body_file" "$slot" "$run_id" "$payload_file" "$request_file" "$result_file" "$status_file" "$target" "$target_engine" "$delivery_mode" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery"

  # Ordering (issue #219): write run_dir artifacts + grant ACLs BEFORE queue
  # task creation so that a daemon worker which immediately claims cannot
  # race ahead of missing request/status/manifest or missing per-run ACLs.
  # task_id=0 is a sentinel placeholder; real queue id is patched in below
  # via bridge_cron_update_*_task_id once the queue record exists.
  created_at="$(bridge_now_iso)"
  bridge_cron_write_request "$request_file" "$run_id" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "0" "$created_at" "$body_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$jobs_file" "$CRON_JOB_PAYLOAD_KIND" "$target_engine" "$target_workdir" "$target_channels" "$target_discord_state_dir" "$target_telegram_state_dir" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery" "$delivery_mode" "$disposable_needs_channels" "$disable_mcp" "$cron_reporting_policy" "$cron_urgency" "$CRON_JOB_PAYLOAD_SHELL_SCRIPT" "$CRON_JOB_PAYLOAD_SHELL_ARGS" "$CRON_JOB_PAYLOAD_SHELL_ENV" "$shell_run_as_agent" "$shell_os_user" "$shell_uid" "$shell_gid" "$shell_home" "$shell_agent_env_file" "$shell_env_snapshot_json" "$CRON_JOB_PAYLOAD_SHELL_TIMEOUT_SECONDS" "$CRON_JOB_PAYLOAD_SHELL_OUTPUT_CAP_BYTES"
  bridge_cron_write_status "$status_file" "$run_id" "queued" "$target_engine" "$request_file" "$result_file" "$created_at"
  bridge_cron_write_manifest "$manifest_file" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "0" "$created_at" "$body_file" "$jobs_file" "$run_id" "$request_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery" "$delivery_mode" "$disposable_needs_channels" "$cron_reporting_policy" "$cron_urgency"
  if [[ "$CRON_JOB_PAYLOAD_KIND" == "shell" ]]; then
    bridge_cron_normalize_shell_run_artifacts "$(bridge_cron_run_dir_by_id "$run_id")" "$request_file" "$status_file" "$payload_file"
  fi
  # Per-run ACL grant is best-effort under v1.3 (#219): the memory-daily
  # harvester now runs as the controller UID, so it does not need the
  # isolated os_user to own/rwX the per-run dir. Other families that do
  # spawn isolated subprocesses can still rely on the grant when sudo/acl
  # infrastructure is available; failure here is non-fatal and does NOT
  # remove the pre-queue artifacts.
  if [[ "$CRON_JOB_PAYLOAD_KIND" != "shell" ]]; then
    bridge_cron_run_dir_grant_isolation "$(bridge_cron_run_dir_by_id "$run_id")" "$target" >/dev/null 2>&1 || true
  fi

  create_output="$(bridge_queue_cli create --to "$target" --title "$title" --from "$actor" --priority "$priority" --body-file "$body_file")"
  printf '%s\n' "$create_output"

  if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  else
    bridge_die "생성된 task id를 파싱하지 못했습니다."
  fi

  bridge_cron_update_request_task_id "$request_file" "$task_id"
  bridge_cron_update_manifest_task_id "$manifest_file" "$task_id"
  if [[ "$CRON_JOB_PAYLOAD_KIND" == "shell" ]]; then
    bridge_cron_normalize_shell_run_artifacts "$(bridge_cron_run_dir_by_id "$run_id")" "$request_file" "$status_file" "$payload_file"
  fi

  printf 'run_id: %s\n' "$run_id"
  printf 'request_file: %s\n' "$request_rel"
  printf 'result_file: %s\n' "$result_rel"
  printf 'status_file: %s\n' "$status_rel"
  printf 'manifest: %s\n' "$manifest_rel"
}

run_subagent() {
  local run_id="${1:-}"
  local dry_run=0
  local request_file=""
  local args=()

  shift || true
  [[ -n "$run_id" ]] || bridge_die "Usage: $(basename "$0") run-subagent <run-id> [--dry-run]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 run-subagent 옵션입니다: $1"
        ;;
    esac
  done

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  [[ -f "$request_file" ]] || bridge_die "cron run request를 찾지 못했습니다: $run_id"

  args=(run --request-file "$request_file")
  if [[ $dry_run -eq 1 ]]; then
    args+=(--dry-run)
  fi

  bridge_cron_runner_python "${args[@]}"
}

run_finalize() {
  local run_id="${1:-}"
  local json_output=0
  local request_file=""

  shift || true
  [[ -n "$run_id" ]] || bridge_die "Usage: $(basename "$0") finalize-run <run-id> [--json]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_output=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 finalize-run 옵션입니다: $1"
        ;;
    esac
  done

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  [[ -f "$request_file" ]] || bridge_die "cron run request를 찾지 못했습니다: $run_id"

  local args=(
    native-finalize-run
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    --request-file "$request_file"
  )
  if [[ $json_output -eq 1 ]]; then
    args+=(--json)
  fi
  bridge_cron_python "${args[@]}"
}

run_sync() {
  local dry_run=0
  local json_output=0
  local since=""
  local now=""
  local native_state_file=""
  local compat_native_state_file="$BRIDGE_CRON_STATE_DIR/native-scheduler-state.json"
  local tmp_dir=""
  local reconcile_json=""
  local legacy_json=""
  local native_json=""
  local cleanup_json=""
  local status=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      --since|--now)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --since) since="$2" ;;
          --now) now="$2" ;;
        esac
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 sync 옵션입니다: $1"
        ;;
    esac
  done

  if [[ ! -f "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]]; then
    printf 'status: skipped\n'
    printf 'reason: no_native_cron_jobs_file\n'
    printf 'native_jobs_file: %s\n' "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    return 0
  fi

  # Issue #1328 (v0.15.0-beta5-2 Lane μ M5): verify cron-state-dir anchor
  # and migrate the old tree if the env-resolved path moved. Best-effort,
  # never aborts sync. See `bridge_cron_state_dir_verify_and_migrate` for
  # the full edge-case matrix.
  if declare -F bridge_cron_state_dir_verify_and_migrate >/dev/null 2>&1; then
    bridge_cron_state_dir_verify_and_migrate >/dev/null 2>&1 || true
  fi

  native_state_file="$(bridge_cron_scheduler_state_file)"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  if [[ $dry_run -eq 0 ]]; then
    if ! bridge_cron_python reconcile-run-state \
      --tasks-db "$BRIDGE_TASK_DB" \
      --runs-dir "$BRIDGE_CRON_STATE_DIR/runs" \
      --json >"$tmp_dir/reconcile.json"; then
      status=1
    fi
    reconcile_json="$tmp_dir/reconcile.json"
  fi

  if [[ -f "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]]; then
    local native_args=(
      sync
      --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
      --state-file "$native_state_file"
      --bridge-cron "$SCRIPT_DIR/bridge-cron.sh"
      --repo-root "$SCRIPT_DIR"
      --enqueue-jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
      --json
    )
    if [[ -n "$since" ]]; then
      native_args+=(--since "$since")
    fi
    if [[ -n "$now" ]]; then
      native_args+=(--now "$now")
    fi
    if [[ $dry_run -eq 1 ]]; then
      native_args+=(--dry-run)
    fi
    if ! bridge_cron_scheduler_python "${native_args[@]}" >"$tmp_dir/native.json"; then
      status=1
    fi
    native_json="$tmp_dir/native.json"

    if [[ $dry_run -eq 0 && -f "$native_state_file" && "$compat_native_state_file" != "$native_state_file" ]]; then
      cp "$native_state_file" "$compat_native_state_file"
    fi

    if [[ $dry_run -eq 0 ]]; then
      if ! bridge_cron_python cleanup-prune \
        --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE" \
        --mode expired-one-shot \
        --json >"$tmp_dir/native-cleanup.json"; then
        status=1
      fi
      cleanup_json="$tmp_dir/native-cleanup.json"

      # Issue #533 — opt-in periodic GC for cron run artifacts. Default OFF
      # to preserve current sync behavior exactly. Operators can enable
      # hands-off retention via:
      #   BRIDGE_CRON_RUN_ARTIFACTS_GC=1 (and optional
      #   BRIDGE_CRON_RUN_ARTIFACTS_OLDER_THAN_DAYS=<N> single-knob).
      # Failures here do NOT flip $status — retention is best-effort and
      # must not block scheduler tick visibility.
      if [[ "${BRIDGE_CRON_RUN_ARTIFACTS_GC:-0}" == "1" ]]; then
        local rga_args=(
          cleanup-prune
          --mode run-artifacts
          --target-root "$BRIDGE_HOME"
          --tasks-db "$BRIDGE_TASK_DB"
          --json
        )
        if [[ -n "${BRIDGE_CRON_RUN_ARTIFACTS_OLDER_THAN_DAYS:-}" ]]; then
          rga_args+=(--older-than-days "$BRIDGE_CRON_RUN_ARTIFACTS_OLDER_THAN_DAYS")
        fi
        bridge_cron_python "${rga_args[@]}" 2>/dev/null >"$tmp_dir/native-run-artifacts-cleanup.json" || true
      fi
    fi
  fi

  bridge_require_python
  python3 - "$legacy_json" "$native_json" "$cleanup_json" "$reconcile_json" "$json_output" <<'PY'
import json
import sys
from pathlib import Path

legacy_path, native_path, cleanup_path, reconcile_path, json_output = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"

def load(path_value):
    if not path_value:
        return None
    path = Path(path_value)
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))

sources = {}
for name, path_value in (("legacy", legacy_path), ("native", native_path)):
    payload = load(path_value)
    if payload is not None:
        sources[name] = payload
cleanup_payload = load(cleanup_path)
reconcile_payload = load(reconcile_path)

if not sources:
    payload = {"status": "skipped", "reason": "no_sources"}
    if json_output:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print("status: skipped")
        print("reason: no_sources")
    raise SystemExit(0)

totals = {
    "eligible_jobs": 0,
    "due_occurrences": 0,
    "created": 0,
    "already_enqueued": 0,
    "errors": 0,
    "cleanup_deleted_jobs": 0,
    "reconciled_cancelled_runs": 0,
}
statuses = []
for source_payload in sources.values():
    summary = source_payload.get("summary", {})
    totals["eligible_jobs"] += int(summary.get("eligible", 0))
    totals["due_occurrences"] += int(summary.get("due_occurrences", 0))
    totals["created"] += sum(1 for item in source_payload.get("results", []) if item.get("status") == "created")
    totals["already_enqueued"] += sum(1 for item in source_payload.get("results", []) if item.get("status") == "already_enqueued")
    totals["errors"] += sum(1 for item in source_payload.get("results", []) if item.get("status") == "error")
    statuses.append(source_payload.get("status", "ok"))
if cleanup_payload is not None:
    totals["cleanup_deleted_jobs"] = int(cleanup_payload.get("deleted_jobs", 0))
if reconcile_payload is not None:
    totals["reconciled_cancelled_runs"] = int(reconcile_payload.get("repaired_runs", 0))

if any(status == "error" for status in statuses) or totals["errors"] > 0:
    status_value = "error"
elif statuses and all(status == "dry_run" for status in statuses):
    status_value = "dry_run"
else:
    status_value = "ok"

payload = {
    "status": status_value,
    "sources": sources,
    "cleanup": cleanup_payload,
    "reconcile": reconcile_payload,
    "totals": totals,
}

if json_output:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
else:
    print(f"status: {status_value}")
    print(f"sources: {', '.join(sorted(sources))}")
    for name in sorted(sources):
        source_payload = sources[name]
        summary = source_payload.get("summary", {})
        results = source_payload.get("results", [])
        created = sum(1 for item in results if item.get("status") == "created")
        already = sum(1 for item in results if item.get("status") == "already_enqueued")
        errors = sum(1 for item in results if item.get("status") == "error")
        print(
            f"{name}: status={source_payload.get('status', 'ok')} "
            f"eligible={summary.get('eligible', 0)} "
            f"due={summary.get('due_occurrences', 0)} "
            f"created={created} already_enqueued={already} errors={errors}"
        )
    print(f"eligible_jobs: {totals['eligible_jobs']}")
    print(f"due_occurrences: {totals['due_occurrences']}")
    print(f"created: {totals['created']}")
    print(f"already_enqueued: {totals['already_enqueued']}")
    print(f"errors: {totals['errors']}")
    if cleanup_payload is not None:
        print(f"cleanup_deleted_jobs: {totals['cleanup_deleted_jobs']}")
    if reconcile_payload is not None:
        print(f"reconciled_cancelled_runs: {totals['reconciled_cancelled_runs']}")
PY
  return "$status"
}

run_errors() {
  local errors_cmd="${1:-}"
  shift || true

  # Issue #1114: short-circuit -h/--help/help BEFORE the
  # bridge_require_cron_source_jobs guard so `cron errors --help` works
  # on hosts without a populated cron source jobs file.
  case "$errors_cmd" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  bridge_require_cron_source_jobs "$jobs_file"

  case "$errors_cmd" in
    report)
      local py_args=(
        errors-report
        --jobs-file "$jobs_file"
      )
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --agent|--family|--limit)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 errors report 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    *)
      bridge_die "지원하지 않는 errors 명령입니다: ${errors_cmd:-<none>}"
      ;;
  esac
}

run_cleanup() {
  local cleanup_cmd="${1:-}"
  shift || true

  # Issue #1114: short-circuit -h/--help/help BEFORE the
  # bridge_require_cron_source_jobs guard so `cron cleanup --help` works
  # on hosts without a populated cron source jobs file.
  case "$cleanup_cmd" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  # Issue #533 — for `--mode run-artifacts` and `--mode all` the cleanup
  # operates on BRIDGE_HOME directly and does not need a jobs file. We
  # peek at the args to decide whether to require the source jobs file.
  local _peek_mode="expired-one-shot"
  local _arg
  for _arg in "$@"; do
    if [[ "$_arg" == "run-artifacts" || "$_arg" == "all" || "$_arg" == "one-shot" || "$_arg" == "expired-one-shot" ]]; then
      _peek_mode="$_arg"
    fi
  done

  local jobs_file=""
  if [[ "$_peek_mode" != "run-artifacts" ]]; then
    jobs_file="$(bridge_cron_source_jobs_file || true)"
    bridge_require_cron_source_jobs "$jobs_file"
  fi

  case "$cleanup_cmd" in
    report)
      local py_args=(cleanup-report)
      [[ -n "$jobs_file" ]] && py_args+=(--jobs-file "$jobs_file")
      py_args+=(--target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB")
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode|--older-than-days|--target-root|--tasks-db)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 cleanup report 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    prune)
      local py_args=(cleanup-prune)
      [[ -n "$jobs_file" ]] && py_args+=(--jobs-file "$jobs_file")
      py_args+=(--target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB")
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode|--older-than-days|--target-root|--tasks-db)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --dry-run|--json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 cleanup prune 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    *)
      bridge_die "지원하지 않는 cleanup 명령입니다: ${cleanup_cmd:-<none>}"
      ;;
  esac
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  inventory)
    run_inventory "$@"
    ;;
  show)
    run_show "$@"
    ;;
  import)
    run_import "$@"
    ;;
  list)
    run_list "$@"
    ;;
  create)
    run_create "$@"
    ;;
  update)
    run_update "$@"
    ;;
  delete)
    run_delete "$@"
    ;;
  rebalance-memory-daily)
    run_rebalance_memory_daily "$@"
    ;;
  migrate-payloads)
    run_migrate_payloads "$@"
    ;;
  enqueue)
    run_enqueue "$@"
    ;;
  sync)
    run_sync "$@"
    ;;
  run-subagent)
    run_subagent "$@"
    ;;
  finalize-run)
    run_finalize "$@"
    ;;
  errors)
    run_errors "$@"
    ;;
  cleanup)
    run_cleanup "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    # Issue #163: attach an intent-recovery suggestion before dying so the
    # caller sees "혹시 X?" instead of just the bare rejection.
    # Refs #1116: `finalize-run` is an internal runtime callback (only
    # bridge-daemon.sh invokes it on cron run completion) — keep it
    # dispatchable above but absent from this typo-suggestion list so
    # operators don't reverse-engineer it from the rejection path. Every
    # other entry is operator-facing.
    _hint="$(bridge_suggest_subcommand "cron $subcommand" \
      "inventory show import list create update delete rebalance-memory-daily migrate-payloads enqueue sync run-subagent errors cleanup")"
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 cron 명령입니다: $subcommand"
    ;;
esac
