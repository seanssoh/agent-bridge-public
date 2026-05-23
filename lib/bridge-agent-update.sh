#!/usr/bin/env bash
# bridge-agent-update.sh — typed audited update path for protected
# agent-roster.local.sh managed-role fields (issue #528).
#
# `agent-bridge agent update <agent>` is the typed/audited mutation
# surface that the tool-policy ROSTER_LOCAL_DENY_REASON used to point at
# vacuously: `agent-bridge config set` rejects non-JSON system-config
# files (see bridge-config.py:cmd_set lines 397-416), and direct
# Edit/Write tool calls are blocked by hooks/tool-policy.py for admin
# too. This module fills that gap by:
#
#  1. Validating the caller is the admin agent AND the source is
#     operator-trusted (TTY-detected or BRIDGE_CALLER_SOURCE override),
#     mirroring the trust model in bridge-config.py:detect_caller_source.
#  2. Computing the new BRIDGE_AGENT_LAUNCH_CMD / BRIDGE_AGENT_CHANNELS
#     value in-memory from typed flags (no shell-aware regex on raw
#     user input — typed flag values carry structured deltas).
#  3. Reusing the existing managed-role block writer
#     (bridge_write_role_block in bridge-agent.sh) with replace_existing=1
#     so emission shape stays consistent with `agent create`.
#  4. Emitting a structured audit row that mirrors
#     bridge-config.py:cmd_set's wrapper-apply detail shape (kind +
#     before/after sha256 + actor + actor_source + operation summary).
#
# Caller validation lives here rather than in tool-policy because the
# wrapper layers caller-source checks on top of admin identity, exactly
# like bridge-config.py does for the JSON wrapper. Tool-policy continues
# to deny direct Edit/Write — this subcommand is the typed surface the
# deny reason directs the admin to.
#
# Out of scope (issue #528 §"out of scope"):
#  - Widening bridge-config.py:cmd_set to non-JSON files.
#  - Admin-only Edit/Write bypass on roster_local_path.
#  - Fixing the dev-channel launch-arg injection bug (#529).

# shellcheck shell=bash

# bridge_agent_update_caller_source — return one of operator-tui /
# operator-trusted-id / agent-direct, mirroring
# bridge-config.py:detect_caller_source. Bash equivalent: respect an
# explicit BRIDGE_CALLER_SOURCE env override first, then fall back to
# TTY detection (stdin+stdout both attached). Anything else is
# agent-direct, which the wrapper rejects.
bridge_agent_update_caller_source() {
  # Strip leading/trailing whitespace before lowercasing — operators
  # editing env files commonly leave a stray space that would otherwise
  # silently demote the source to agent-direct. Mirrors
  # bridge-config.py:94 (`.strip().lower()`).
  local explicit="${BRIDGE_CALLER_SOURCE:-}"
  explicit="$(printf '%s' "$explicit" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  explicit="${explicit,,}"
  case "$explicit" in
    operator-tui|operator-trusted-id)
      printf '%s' "$explicit"
      return 0
      ;;
    "")
      ;;
    *)
      printf '%s' "agent-direct"
      return 0
      ;;
  esac
  if [[ -t 0 && -t 1 ]]; then
    printf '%s' "operator-tui"
    return 0
  fi
  printf '%s' "agent-direct"
}

# bridge_agent_update_caller_agent — caller agent id from --from <agent>
# (already extracted by run_update) or BRIDGE_AGENT_ID env. Empty when
# both are unset; the strict admin check rejects anonymous callers.
bridge_agent_update_caller_agent() {
  # Strip whitespace from --from value or BRIDGE_AGENT_ID env to match
  # bridge-config.py:111 (`str(explicit).strip()` and the env strip on
  # line 115). Without this, a trailing newline in BRIDGE_AGENT_ID
  # passes the non-empty check but fails string equality against the
  # admin id.
  local explicit="${1:-}"
  explicit="$(printf '%s' "$explicit" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  local env_id="${BRIDGE_AGENT_ID:-}"
  env_id="$(printf '%s' "$env_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$env_id"
}

# bridge_agent_update_caller_is_admin — strict admin identity check
# matching bridge-config.py:caller_is_admin (codex r1 #341 CP5):
# the caller agent id must be non-empty AND equal to BRIDGE_ADMIN_AGENT_ID.
# Anonymous callers fail even from operator-TUI; operators running from
# a raw shell must pass --from <admin-agent> explicitly.
bridge_agent_update_caller_is_admin() {
  # Strip both sides before comparing — bridge-config.py:107
  # (`os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()`) and the
  # caller-id strip happen before equality. The shared
  # bridge_admin_agent_id() helper passes through the raw env value
  # unchanged for back-compat with other call sites; we strip locally
  # so a trailing newline in BRIDGE_ADMIN_AGENT_ID does not silently
  # deny every legitimate admin call.
  local agent="${1:-}"
  agent="$(printf '%s' "$agent" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  local admin
  admin="$(bridge_admin_agent_id)"
  admin="$(printf '%s' "$admin" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$admin" && -n "$agent" && "$agent" == "$admin" ]]
}

# bridge_agent_update_validate_channel_token — accepts the channel token
# forms Claude understands on argv: plugin:NAME@SPEC and server:NAME.
bridge_agent_update_validate_channel_token() {
  local flag="$1"
  local token="$2"

  case "$token" in
    plugin:*@*)
      if [[ "$token" =~ ^plugin:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]]; then
        return 0
      fi
      ;;
    server:*)
      if [[ "$token" =~ ^server:[A-Za-z0-9_.-]+$ ]]; then
        return 0
      fi
      ;;
  esac

  bridge_die "$flag token invalid (need plugin:NAME@SPEC or server:NAME): $token"
}

# bridge_agent_update_validate_channels_csv — split a --channels-set
# CSV on `,`, strip per-token whitespace, and reject any non-empty token
# that is not a supported Claude channel selector.
# Trailing-comma tolerance: empty tokens are skipped silently, so an
# operator can pass `plugin:foo@m,` without tripping the validator.
# Calls bridge_die on the first invalid token.
bridge_agent_update_validate_channels_csv() {
  local flag="$1"
  local raw="$2"
  local _IFS_save="$IFS"
  local -a _tokens=()
  IFS=',' read -r -a _tokens <<<"$raw"
  IFS="$_IFS_save"
  local tok trimmed
  for tok in "${_tokens[@]}"; do
    trimmed="$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$trimmed" ]] && continue
    bridge_agent_update_validate_channel_token "$flag" "$trimmed"
  done
}

bridge_agent_update_file_sha256() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf '%s' ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  bridge_require_python
  python3 - "$path" <<'PY'
import hashlib, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    print(hashlib.sha256(p.read_bytes()).hexdigest())
except OSError:
    print("")
PY
}

# bridge_agent_update_apply_launch_cmd — compute the new launch_cmd
# string from a starting value plus a sequence of typed mutations.
# Mutations are encoded as a TSV stream on stdin where each line is:
#
#   set-launch-cmd\t<full string>
#   add-env\tKEY=VALUE
#   remove-env\tKEY
#   add-dev-channel\tplugin:x@spec
#   remove-dev-channel\tplugin:x@spec
#
# We delegate to python3 because the mutations need careful tokenizing
# of the env-prefix vs argv portion (the segment before vs after the
# first non-VAR=VALUE token, e.g. `claude`). Idempotency: each add is
# a no-op if the same fragment is already present; each remove is a
# no-op if the fragment is already absent. The actions array reports
# only the deltas that changed the value.
#
# Stdout: two lines.
#   line 1: <new launch_cmd>
#   line 2: <JSON array of action strings that changed the value>
bridge_agent_update_apply_launch_cmd() {
  local current="$1"
  bridge_require_python
  # Issue #815 Wave A: the body of this applier used to live in a
  # `$(cat <<'PY' ... PY)` source-time capture. On a stale runtime that
  # hung Bash in `heredoc_write` while sourcing this module, which in
  # turn hung the CLI hot path. The body now lives in a regular file
  # under scripts/python-helpers/, so no source-time read occurs.
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  BRIDGE_AGENT_UPDATE_LC_CURRENT="$current" \
    python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/agent-update-apply-launch-cmd.py"
}

# bridge_agent_update_apply_channels — compute the new channels CSV
# from a starting value plus typed mutations on stdin (TSV):
#
#   channels-set\t<csv>
#   channels-add\t<token>
#   channels-remove\t<token>
#
# Stdout: two lines (new csv, json action array).
#
# Issue #815 Wave A: like the launch-cmd applier above, the body now
# lives in scripts/python-helpers/ rather than a source-time heredoc
# capture. See agent-update-apply-launch-cmd rationale.
bridge_agent_update_apply_channels() {
  local current="$1"
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  BRIDGE_AGENT_UPDATE_CH_CURRENT="$current" \
    python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/agent-update-apply-channels.py"
}

# bridge_agent_update_emit_audit — write a system_config_mutation row
# matching bridge-config.py:cmd_set's shape for the agent-update
# trigger. trigger_label is one of `agent-update-deny` /
# `agent-update-apply` / `agent-update-dry-run`.
bridge_agent_update_emit_audit() {
  local trigger_label="$1"
  local actor="$2"
  local actor_source="$3"
  local target_agent="$4"
  local roster_path="$5"
  local before_sha="$6"
  local after_sha="$7"
  local operation="$8"
  local reason="${9:-}"
  local before_launch_cmd="${10:-}"
  local after_launch_cmd="${11:-}"
  local before_channels="${12:-}"
  local after_channels="${13:-}"
  local actions_json="${14:-[]}"
  # Issue #1093: optional before/after idle_timeout and loop deltas.
  # Optional positionals (default empty strings) keep existing callers
  # working byte-identically — the audit-detail helper emits the new
  # fields only when at least one value is supplied so old audit-log
  # parsers stay forward-compatible.
  local before_idle_timeout="${15:-}"
  local after_idle_timeout="${16:-}"
  local before_loop="${17:-}"
  local after_loop="${18:-}"

  bridge_require_python
  # #946 L1 (r2): stale-source guard before either of the two python3
  # forks below. The audit-detail-json invocation happens INSIDE `$()`,
  # which is exactly the substitution-swallow site codex P1 #2 flagged
  # — without the guard a stale checkout silently emits an empty
  # detail_json and the subsequent audit.py call lands with garbage
  # input. The check helper writes one audit line to BRIDGE_DAEMON_LOG
  # (not the audit log we cannot reach) so the failure is visible.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  local detail_json
  # Footgun #11 (KNOWN_ISSUES.md §26): this used to be `python3 - …
  # <<'PY' … PY` inside a `$()` capture. Bash 5.3.9 `heredoc_write`
  # deadlocks the moment any CRUD path emits an audit row, so the
  # unregistered agent-update / agent-delete smokes never finished on
  # the operator host. Standalone helper invoked file-as-argv removes
  # the heredoc-stdin path; same shape PR #940 used for registry/list
  # /show.
  detail_json="$(
    python3 "$BRIDGE_SCRIPT_DIR/lib/agent-cli-helpers/audit-detail-json.py" \
      "$trigger_label" \
      "$actor" \
      "$actor_source" \
      "$target_agent" \
      "$roster_path" \
      "$before_sha" \
      "$after_sha" \
      "$operation" \
      "$reason" \
      "$before_launch_cmd" \
      "$after_launch_cmd" \
      "$before_channels" \
      "$after_channels" \
      "$actions_json" \
      "$before_idle_timeout" \
      "$after_idle_timeout" \
      "$before_loop" \
      "$after_loop"
  )"

  python3 "$BRIDGE_SCRIPT_DIR/bridge-audit.py" write \
    --file "${BRIDGE_AUDIT_LOG:-$BRIDGE_HOME/logs/audit.jsonl}" \
    --actor "wrapper" \
    --action "system_config_mutation" \
    --target "$roster_path" \
    --detail-json "$detail_json" >/dev/null 2>&1 || true
}

# bridge_agent_update_emit_json — pretty-print the result envelope.
#
# Footgun #11 (KNOWN_ISSUES.md §26): the body used to be a
# `python3 - … <<'PY' … PY` heredoc-stdin block. Issue #1023 also needs
# this surface to redact credential-bearing launch-cmd env values, so
# the body was extracted to lib/agent-cli-helpers/agent-update-result-json.py
# (invoked file-as-argv) — the heredoc-stdin path is gone and the
# redaction lives in the shared launch-cmd-redact module the helper
# imports.
bridge_agent_update_emit_json() {
  local agent="$1"
  local changed="$2"
  local dry_run="$3"
  local before_launch_cmd="$4"
  local after_launch_cmd="$5"
  local before_channels="$6"
  local after_channels="$7"
  local before_sha="$8"
  local after_sha="$9"
  local actions_json="${10}"
  # Issue #1093: optional before/after idle_timeout and loop deltas.
  # Optional positionals (default empty) so existing callers stay
  # working; the result helper drops empty deltas from the JSON
  # envelope so a no-policy-mutation call still produces a byte-stable
  # output for downstream pipelines.
  local before_idle_timeout="${11:-}"
  local after_idle_timeout="${12:-}"
  local before_loop="${13:-}"
  local after_loop="${14:-}"

  bridge_require_python
  # #946 L1: stale-source guard before the python3 fork.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/lib/agent-cli-helpers/agent-update-result-json.py" \
    "$agent" \
    "$changed" \
    "$dry_run" \
    "$before_launch_cmd" \
    "$after_launch_cmd" \
    "$before_channels" \
    "$after_channels" \
    "$before_sha" \
    "$after_sha" \
    "$actions_json" \
    "$before_idle_timeout" \
    "$after_idle_timeout" \
    "$before_loop" \
    "$after_loop"
}
