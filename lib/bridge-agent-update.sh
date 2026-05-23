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
# explicit BRIDGE_CALLER_SOURCE env override first, then auto-promote
# admin-agent sessions (issue #1122), then fall back to TTY detection
# (stdin+stdout both attached). Anything else is agent-direct, which
# the wrapper rejects.
#
# Issue #1122 — admin Claude Code sessions: when the caller is
# identifiably the admin agent (`BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID`,
# both non-empty), promote the source to `operator-trusted-id` even
# without an explicit `BRIDGE_CALLER_SOURCE` override. The Claude Code
# Bash tool runs each command in a non-interactive subshell that the
# TTY-detection branch never matches, so the only practical workaround
# from inside an admin session was to hard-set the env on every
# mutating subcommand. The auto-promotion closes that workflow gap
# without weakening the non-admin rejection: a non-admin session with
# no explicit override still falls through to agent-direct.
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
  # Issue #1122: admin-session auto-promotion. Placed BEFORE the TTY
  # branch so a Claude Code Bash tool subshell (no TTY) inside the
  # admin agent is treated as operator-trusted. The agent-id check
  # mirrors bridge_agent_update_caller_is_admin: both sides stripped,
  # both must be non-empty, and they must compare equal. A non-admin
  # session (BRIDGE_AGENT_ID set but not equal to BRIDGE_ADMIN_AGENT_ID)
  # is NOT promoted and falls through to TTY / agent-direct.
  local _session_agent _admin_agent
  _session_agent="${BRIDGE_AGENT_ID:-}"
  _session_agent="$(printf '%s' "$_session_agent" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  _admin_agent="$(printf '%s' "$_admin_agent" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$_session_agent" && -n "$_admin_agent" && "$_session_agent" == "$_admin_agent" ]]; then
    bridge_agent_update_emit_caller_source_auto_promotion_audit "$_session_agent" "admin-agent-signal"
    printf '%s' "operator-trusted-id"
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    printf '%s' "operator-tui"
    return 0
  fi
  printf '%s' "agent-direct"
}

# bridge_agent_update_emit_caller_source_auto_promotion_audit — issue
# #1122. Emit a single `caller_source_auto_promotion` audit row when the
# admin-session signal upgrades an otherwise-agent-direct caller to
# `operator-trusted-id`. Once-per-process (gated by
# `BRIDGE_AGENT_CALLER_SOURCE_AUTO_PROMOTED`) so a single CLI
# invocation that calls bridge_agent_update_caller_source() multiple
# times produces exactly one audit row. Best-effort: failure to write
# the audit row never blocks the underlying mutation, since the row is
# diagnostic — the existing system_config_mutation row remains the
# authoritative apply/deny record.
bridge_agent_update_emit_caller_source_auto_promotion_audit() {
  local actor="$1"
  local derived_from="$2"
  if [[ "${BRIDGE_AGENT_CALLER_SOURCE_AUTO_PROMOTED:-0}" == "1" ]]; then
    return 0
  fi
  export BRIDGE_AGENT_CALLER_SOURCE_AUTO_PROMOTED=1
  # Resolve audit log path the same way bridge_agent_update_emit_audit
  # does — honor BRIDGE_AUDIT_LOG override, else default under
  # BRIDGE_HOME. Skip entirely when neither is resolvable; the audit
  # event is diagnostic and the mutation itself is still gated.
  local _audit_log="${BRIDGE_AUDIT_LOG:-}"
  if [[ -z "$_audit_log" ]]; then
    if [[ -n "${BRIDGE_HOME:-}" ]]; then
      _audit_log="$BRIDGE_HOME/logs/audit.jsonl"
    else
      return 0
    fi
  fi
  # Ensure the parent directory exists (best-effort) so the first
  # auto-promotion in a fresh BRIDGE_HOME does not silently lose the
  # row to a missing logs/ dir.
  mkdir -p "$(dirname "$_audit_log")" 2>/dev/null || true
  command -v python3 >/dev/null 2>&1 || return 0
  # Resolve BRIDGE_SCRIPT_DIR — fall back to the parent of this file's
  # `lib/` so the helper works when sourced standalone (no caller has
  # initialized BRIDGE_SCRIPT_DIR yet).
  local _script_dir="${BRIDGE_SCRIPT_DIR:-}"
  if [[ -z "$_script_dir" || ! -x "$_script_dir/bridge-audit.py" ]]; then
    _script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)"
  fi
  [[ -f "$_script_dir/bridge-audit.py" ]] || return 0
  local _helper="$_script_dir/lib/agent-cli-helpers/caller-source-auto-promotion-detail-json.py"
  [[ -f "$_helper" ]] || return 0
  local _detail_json
  # Footgun #11 guard: invoke the detail-json helper file-as-argv (no
  # heredoc-stdin inside the `$()` capture). Same shape PR #940 used
  # for registry/list/show, and PR #4773's audit-detail-json extraction
  # for agent update/delete.
  _detail_json="$(python3 "$_helper" "$actor" "$derived_from")"
  python3 "$_script_dir/bridge-audit.py" write \
    --file "$_audit_log" \
    --actor "$actor" \
    --action "caller_source_auto_promotion" \
    --target "$actor" \
    --detail-json "$_detail_json" >/dev/null 2>&1 || true
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
