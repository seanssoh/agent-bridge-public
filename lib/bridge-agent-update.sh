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

# bridge_agent_update_validate_channels_csv — split a --channels-set
# CSV on `,`, strip per-token whitespace, and reject any non-empty token
# that does not match the plugin:NAME@SPEC shape (codex r1 finding 4).
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
    if [[ ! "$trimmed" =~ ^plugin:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]]; then
      bridge_die "$flag token invalid (need plugin:NAME@SPEC): $trimmed"
    fi
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
  # Pass the python source via -c (env var carries the script body) so
  # the heredoc approach does not collide with the caller's TSV stream
  # piped into python's stdin. See sister channels-applier below.
  BRIDGE_AGENT_UPDATE_LC_CURRENT="$current" python3 -c "$_BRIDGE_AGENT_UPDATE_APPLY_LC_PY"
}

# Source for bridge_agent_update_apply_launch_cmd. Stored in a string so
# python3 -c "$..." receives the body cleanly while the heredoc-form
# stdin remains free for the caller-provided TSV stream.
_BRIDGE_AGENT_UPDATE_APPLY_LC_PY=$(cat <<'PY'
import json
import os
import re
import sys

current = os.environ.get("BRIDGE_AGENT_UPDATE_LC_CURRENT", "")


def split_env_prefix(value: str) -> tuple[list[str], list[str]]:
    """Return (env_prefix_tokens, argv_tokens).

    env_prefix is the leading run of ``KEY=VALUE`` tokens (no leading
    dash, must contain ``=``, key matches ``[A-Za-z_][A-Za-z0-9_]*``).
    Everything from the first non-env token onwards is argv. We
    tokenize whitespace-naively: the launch_cmd is operator-authored
    in roster.local.sh and is shell-quoted on emission, so a single
    space split is sufficient for the env/argv boundary.
    """
    tokens = value.split()
    env_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    env: list[str] = []
    argv: list[str] = []
    boundary_seen = False
    for tok in tokens:
        if not boundary_seen and not tok.startswith("-") and env_re.match(tok):
            env.append(tok)
        else:
            boundary_seen = True
            argv.append(tok)
    return env, argv


def reassemble(env: list[str], argv: list[str]) -> str:
    pieces: list[str] = []
    pieces.extend(env)
    pieces.extend(argv)
    return " ".join(pieces).strip()


def env_key(token: str) -> str:
    return token.split("=", 1)[0]


def add_env(env: list[str], pair: str) -> bool:
    """Idempotent prepend of KEY=VALUE.

    No-op if the same KEY=VALUE token is already in the env prefix
    (in any position). If a different value for KEY is present, the
    contract is "prepend" — we add the new pair at the front; the
    operator removed-then-added if they wanted to change a value.
    """
    if pair in env:
        return False
    env.insert(0, pair)
    return True


def remove_env(env: list[str], key: str) -> bool:
    """Remove every ``KEY=...`` token from the env prefix."""
    keep: list[str] = []
    removed = False
    for tok in env:
        if env_key(tok) == key:
            removed = True
            continue
        keep.append(tok)
    env[:] = keep
    return removed


def add_dev_channel(argv: list[str], spec: str) -> bool:
    """Append ``--dangerously-load-development-channels <spec>`` to argv.

    Idempotent: skip if the option-paired form (whitespace OR ``=``)
    is already present anywhere in argv.
    """
    pair_ws = ["--dangerously-load-development-channels", spec]
    pair_eq = f"--dangerously-load-development-channels={spec}"
    # Whitespace form: option followed immediately by spec.
    for i in range(len(argv) - 1):
        if argv[i] == pair_ws[0] and argv[i + 1] == pair_ws[1]:
            return False
    # = form: option=spec as a single token.
    if pair_eq in argv:
        return False
    argv.append(pair_ws[0])
    argv.append(pair_ws[1])
    return True


def remove_dev_channel(argv: list[str], spec: str) -> bool:
    """Strip the option/spec pair (whitespace + ``=`` forms) and any
    dangling bare ``spec`` token left behind by an operator partial
    edit. Mirrors the cleanup logic in bridge-relay-cleanup.py
    (RELAY_DEV_CHANNEL_RE / RELAY_BARE_TOKEN_RE) but parameterised on
    the user-supplied spec rather than hard-coded telegram-relay.
    """
    pair_eq = f"--dangerously-load-development-channels={spec}"
    new: list[str] = []
    removed = False
    i = 0
    while i < len(argv):
        tok = argv[i]
        nxt = argv[i + 1] if i + 1 < len(argv) else None
        if tok == "--dangerously-load-development-channels" and nxt == spec:
            removed = True
            i += 2
            continue
        if tok == pair_eq:
            removed = True
            i += 1
            continue
        if tok == spec:
            # Dangling bare token (operator hand-edited only the
            # option half away). Cleaning this matches the
            # bridge-relay-cleanup contract for parity.
            removed = True
            i += 1
            continue
        new.append(tok)
        i += 1
    argv[:] = new
    return removed


value = current
env, argv = split_env_prefix(value)
actions: list[str] = []

for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t", 1)
    if len(parts) != 2:
        continue
    op, payload = parts[0], parts[1]
    if op == "set-launch-cmd":
        new_value = payload
        if new_value != value:
            value = new_value
            env, argv = split_env_prefix(value)
            actions.append(f"set-launch-cmd")
        continue
    if op == "add-env":
        if "=" not in payload:
            print(f"--launch-cmd-add-env requires KEY=VALUE, got: {payload}", file=sys.stderr)
            sys.exit(2)
        if add_env(env, payload):
            actions.append(f"add-env {payload}")
        value = reassemble(env, argv)
        continue
    if op == "remove-env":
        if remove_env(env, payload):
            actions.append(f"remove-env {payload}")
        value = reassemble(env, argv)
        continue
    if op == "add-dev-channel":
        if add_dev_channel(argv, payload):
            actions.append(f"add-dev-channel {payload}")
        value = reassemble(env, argv)
        continue
    if op == "remove-dev-channel":
        if remove_dev_channel(argv, payload):
            actions.append(f"remove-dev-channel {payload}")
        value = reassemble(env, argv)
        continue
    print(f"unknown launch-cmd op: {op}", file=sys.stderr)
    sys.exit(2)

print(value)
print(json.dumps(actions, ensure_ascii=False))
PY
)

# bridge_agent_update_apply_channels — compute the new channels CSV
# from a starting value plus typed mutations on stdin (TSV):
#
#   channels-set\t<csv>
#   channels-add\t<token>
#   channels-remove\t<token>
#
# Stdout: two lines (new csv, json action array).
bridge_agent_update_apply_channels() {
  local current="$1"
  bridge_require_python
  BRIDGE_AGENT_UPDATE_CH_CURRENT="$current" python3 -c "$_BRIDGE_AGENT_UPDATE_APPLY_CH_PY"
}

_BRIDGE_AGENT_UPDATE_APPLY_CH_PY=$(cat <<'PY'
import json
import os
import sys


def split_csv(raw: str) -> list[str]:
    if not raw:
        return []
    return [item.strip() for item in raw.split(",") if item.strip()]


def join_csv(items: list[str]) -> str:
    return ",".join(items)


value = os.environ.get("BRIDGE_AGENT_UPDATE_CH_CURRENT", "")
items = split_csv(value)
actions: list[str] = []

for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t", 1)
    if len(parts) != 2:
        continue
    op, payload = parts[0], parts[1]
    if op == "channels-set":
        new_items = split_csv(payload)
        if new_items != items:
            items = new_items
            actions.append("channels-set")
        continue
    if op == "channels-add":
        if payload and payload not in items:
            items.append(payload)
            actions.append(f"channels-add {payload}")
        continue
    if op == "channels-remove":
        if payload and payload in items:
            items.remove(payload)
            actions.append(f"channels-remove {payload}")
        continue
    print(f"unknown channels op: {op}", file=sys.stderr)
    sys.exit(2)

print(join_csv(items))
print(json.dumps(actions, ensure_ascii=False))
PY
)

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

  bridge_require_python
  local detail_json
  detail_json="$(
    python3 - \
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
      "$actions_json" <<'PY'
import json
import sys

(
    trigger,
    actor,
    actor_source,
    target_agent,
    path,
    before_sha,
    after_sha,
    operation,
    reason,
    before_launch_cmd,
    after_launch_cmd,
    before_channels,
    after_channels,
    actions_json,
) = sys.argv[1:]

# Mirror bridge-config.py:cmd_set's wrapper-apply / wrapper-deny detail
# shape so end-to-end audit verification (`agent-bridge audit verify`)
# treats agent-update rows the same way it treats config-set rows.
detail = {
    "kind": "system_config_mutation",
    "actor": actor,
    "actor_source": actor_source,
    "trigger": trigger,
    "path": path,
    "before_sha256": before_sha,
    "operation": operation,
    "matched_pattern": "agent-roster.local.sh",
    "target_agent": target_agent,
    "before_launch_cmd": before_launch_cmd,
    "after_launch_cmd": after_launch_cmd,
    "before_channels": before_channels,
    "after_channels": after_channels,
}
if after_sha:
    detail["after_sha256"] = after_sha
if reason:
    detail["reason"] = reason
try:
    detail["actions"] = json.loads(actions_json) if actions_json else []
except (TypeError, ValueError):
    detail["actions"] = []
print(json.dumps(detail, ensure_ascii=True, sort_keys=True))
PY
  )"

  python3 "$BRIDGE_SCRIPT_DIR/bridge-audit.py" write \
    --file "${BRIDGE_AUDIT_LOG:-$BRIDGE_HOME/logs/audit.jsonl}" \
    --actor "wrapper" \
    --action "system_config_mutation" \
    --target "$roster_path" \
    --detail-json "$detail_json" >/dev/null 2>&1 || true
}

# bridge_agent_update_emit_json — pretty-print the result envelope.
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

  bridge_require_python
  python3 - \
    "$agent" \
    "$changed" \
    "$dry_run" \
    "$before_launch_cmd" \
    "$after_launch_cmd" \
    "$before_channels" \
    "$after_channels" \
    "$before_sha" \
    "$after_sha" \
    "$actions_json" <<'PY'
import json
import sys

(
    agent,
    changed,
    dry_run,
    before_launch_cmd,
    after_launch_cmd,
    before_channels,
    after_channels,
    before_sha,
    after_sha,
    actions_json,
) = sys.argv[1:]

try:
    actions = json.loads(actions_json) if actions_json else []
except (TypeError, ValueError):
    actions = []

payload = {
    "agent": agent,
    "changed": changed == "1",
    "dry_run": dry_run == "1",
    "before": {
        "launch_cmd": before_launch_cmd,
        "channels": before_channels,
    },
    "after": {
        "launch_cmd": after_launch_cmd,
        "channels": after_channels,
    },
    "before_sha": before_sha,
    "after_sha": after_sha,
    "actions": actions,
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}
