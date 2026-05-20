#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# bridge-isolation-v3-channel-dotenv.sh — Channel-dotenv migrator from
# the legacy ACL-grant contract (v2 era, controller-owned mode 0640 or
# 0660 + named-user ACL granting read to each isolated UID) to the
# v0.13.4 contract (isolated-UID-owned mode 0600, no extended ACL).
#
# Public entrypoint: bridge_isolation_v3_channel_dotenv_cli (dispatched
# from bridge-migrate.sh as `agent-bridge migrate isolation v3 ...`).
#
# Modes:
#   --check       drift detection only — record `drift` rows for paths
#                 whose current state differs from canonical; no
#                 mutation.
#   --dry-run     (default — operator must opt into --apply explicitly)
#                 record `would` rows describing the exact action
#                 --apply would take. No mutation.
#   --apply       perform the mutations. Idempotent — a second --apply
#                 on a clean tree records `ok:already-canonical` rows
#                 and performs no filesystem mutation.
#   --agent <X>   scope to one agent (default: every linux-user-isolated
#                 agent in the roster).
#   --json        emit JSON instead of human-readable text.
#
# Target state per file (under each isolated agent's
# $agent_workdir/.{discord,telegram,teams,ms365,mattermost}/):
#   .env          isolated-UID:ab-agent-<slug>  0600  no extended ACL
#   access.json   isolated-UID:ab-agent-<slug>  0600  no extended ACL
#   state.json    isolated-UID:ab-agent-<slug>  0600  no extended ACL  (teams only)
#   mcp.json      isolated-UID:ab-agent-<slug>  0600  no extended ACL  (mattermost only)
#
# Path guards:
#   - refuse symlinks
#   - refuse non-regular files
#   - parent dir basename MUST equal `.<provider>`
#   - when agent_workdir is resolvable, the file MUST live under
#     <agent_workdir>/.<provider>/
#
# Platform: macOS / non-Linux hosts have no isolated UID concept and no
# `setfacl`. The CLI is a contract no-op on those hosts: it returns 0
# with no stdout — neither text nor JSON — so operators do not mistake
# non-Linux invocation for a meaningful result.
#
# Active-session safety: this tool only mutates ownership / mode / ACL
# bits on already-existing channel dotenvs. It does not stop or restart
# the daemon and does not touch the queue. Operators may run --apply on
# a live install; worst case is a transient probe miss during the
# chown window (bridge-start and the daemon carry no self-heal fallback
# for channel dotenvs — this tool is the canonical recovery path).
#
# Why a separate tool from v2 reapply:
#
# v2 reapply (bridge-isolation-v2-reapply.sh) asserts the LAYOUT-level
# v2 contract (group + setgid model, no ACL). Its channel-dotenv row
# asserts target mode 0660 (group-readable so the controller — a
# member of ab-agent-<slug> per the v2 design — can read via the base
# group bit). That contract is the LEGACY pre-v0.13.4 shape.
#
# v0.13.4 introduced the replacement (#857 PR-2 / PR-3): controller-blind
# via sudo-as-isolated-UID for BOTH read AND write, so the channel
# dotenv goes to mode 0600 (owner-only) and no extended ACL is needed.
# This v3 tool migrates existing installs that still carry the legacy
# 0640/0660 + ACL-grant shape to the new 0600 + no-ACL shape.
# The stop-gap helper bridge_isolation_v2_apply_channel_state_dotenv_acl
# that previously ran at start/daemon as a self-heal has been retired
# (#998 PR B); `agent-bridge migrate isolation v3 --check` is the
# canonical path for diagnosing and repairing drift.

# ---------------------------------------------------------------------------
# 1. helpers — agent enumeration
# ---------------------------------------------------------------------------

bridge_isolation_v3_channel_dotenv_eligible_agents() {
  # Print one agent id per line for every roster agent declared as
  # linux-user isolation mode. v3 reuses v2 reapply's enumerator — the
  # eligibility contract is identical.
  if command -v bridge_isolation_v2_reapply_eligible_agents >/dev/null 2>&1; then
    bridge_isolation_v2_reapply_eligible_agents
    return $?
  fi
  # Fallback path — only reached when this module is loaded without
  # v2 reapply (shouldn't happen in normal dispatch since bridge-lib.sh
  # sources v2 reapply first, but the fallback is defensive against
  # alternate load orders such as direct `source` from a test harness).
  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 0
  local _agent
  for _agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$_agent" ]] || continue
    if [[ "$(bridge_agent_isolation_mode "$_agent" 2>/dev/null || printf '')" == "linux-user" ]]; then
      printf '%s\n' "$_agent"
    fi
  done
}

# ---------------------------------------------------------------------------
# 2. per-path asserter
# ---------------------------------------------------------------------------

bridge_isolation_v3_channel_dotenv_assert_path() {
  # Assert one file's canonical target state. Records exactly one action
  # row per call via bridge_isolation_v2_reapply_record_action.
  #
  # Mirrors bridge_isolation_v2_reapply_assert (file kind) EXCEPT:
  #   - it explicitly strips ALL extended ACLs (setfacl -b, base entries
  #     only) BEFORE the chown+chmod when an ACL is present.
  #   - skipping when path does not exist is silent ok:absent.
  local mode="$1"
  local apply="$2"
  local actions_file="$3"
  local errors_file="$4"
  local path="$5"
  local expected_og="$6"
  local expected_mode_oct="$7"

  # Path guards (defense in depth — the migrate_agent walker already
  # enforces parent-dir / workdir checks, but asserter must not assume
  # an honest caller).
  if [[ -L "$path" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" "v3_channel_dotenv" "symlink" \
      "$expected_og $expected_mode_oct acl=no" "error:refused_symlink"
    printf 'refused symlink at %s\n' "$path" >> "$errors_file"
    return 1
  fi
  if [[ ! -e "$path" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" "v3_channel_dotenv" "absent" \
      "$expected_og $expected_mode_oct acl=no" "ok:absent"
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" "v3_channel_dotenv" "non-regular" \
      "$expected_og $expected_mode_oct acl=no" "error:not_regular_file"
    printf 'non-regular file at %s\n' "$path" >> "$errors_file"
    return 1
  fi

  # Probe current state.
  local probe current_og current_mode current_acl
  probe="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$path")"
  current_og="${probe% *}"
  current_mode="${probe##* }"
  current_acl="no"
  # v3 contract is "no extended ACL at all" — detect named entries AND a
  # residual `mask::` / `default:` (has_named_acl would false-clean a
  # mask-only file and let --check claim already-canonical).
  if bridge_isolation_v2_reapply_has_extended_acl "$path"; then
    current_acl="yes"
  fi

  # Normalize mode for compare (`stat` may emit `600` or `0600`).
  local current_mode_norm="$current_mode"
  local expected_mode_norm="$expected_mode_oct"
  if [[ "$current_mode" =~ ^[0-7]+$ ]]; then
    current_mode_norm=$((10#$current_mode))
  fi
  if [[ "$expected_mode_oct" =~ ^[0-7]+$ ]]; then
    expected_mode_norm=$((10#$expected_mode_oct))
  fi

  local already_canonical="no"
  if [[ "$current_og" == "$expected_og" \
        && "$current_mode_norm" == "$expected_mode_norm" \
        && "$current_acl" == "no" ]]; then
    already_canonical="yes"
  fi

  local before_repr="$current_og $current_mode acl=$current_acl"
  local after_repr="$expected_og $expected_mode_oct acl=no"

  # --check mode → only emit drift or already-canonical
  if [[ "$mode" == "check" ]]; then
    if [[ "$already_canonical" == "yes" ]]; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$path" "v3_channel_dotenv" \
        "$before_repr" "$after_repr" "ok:already-canonical"
    else
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$path" "v3_channel_dotenv" \
        "$before_repr" "$after_repr" "drift"
    fi
    return 0
  fi

  # --dry-run mode → record `would` rows (or already-canonical when clean)
  if [[ "$apply" != "1" ]]; then
    if [[ "$already_canonical" == "yes" ]]; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$path" "v3_channel_dotenv" \
        "$before_repr" "$after_repr" "ok:already-canonical"
    else
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$path" "v3_channel_dotenv" \
        "$before_repr" "$after_repr" "would"
    fi
    return 0
  fi

  # --apply mode → mutate.
  if [[ "$already_canonical" == "yes" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" "v3_channel_dotenv" \
      "$before_repr" "$after_repr" "ok:already-canonical"
    return 0
  fi

  # Strip ALL extended ACL entries first via `setfacl -b` (removes every
  # named-user/named-group entry AND the mask, leaving only base owner /
  # group / other). This MUST happen before chmod so chmod sets the
  # group base entry directly rather than the ACL mask on Linux.
  # bridge_isolation_v2_reapply_chown_chmod_file ALSO strips on demand
  # internally — the double-strip here is intentional belt-and-braces;
  # setfacl -b is idempotent.
  if command -v setfacl >/dev/null 2>&1 && [[ "$current_acl" == "yes" ]]; then
    if ! bridge_isolation_v2_reapply_run_priv setfacl -b "$path"; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$path" "v3_channel_dotenv" \
        "$before_repr" "$after_repr" "error:setfacl_b_failed"
      printf 'setfacl -b failed on %s\n' "$path" >> "$errors_file"
      return 1
    fi
  fi

  # chown + chmod via the v2 reapply primitive (handles direct-then-sudo
  # and an additional ACL-strip-before-chmod internally).
  if ! bridge_isolation_v2_reapply_chown_chmod_file \
        "$expected_og" "$expected_mode_oct" "$path"; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" "v3_channel_dotenv" \
      "$before_repr" "$after_repr" "error:chown_chmod_failed"
    printf 'chown/chmod failed on %s (need root or passwordless sudo)\n' "$path" >> "$errors_file"
    return 1
  fi

  # Re-probe so the `after` column reflects what we actually wrote.
  local after_probe after_acl after_repr_ok
  after_probe="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$path")"
  after_acl="no"
  if bridge_isolation_v2_reapply_has_extended_acl "$path"; then
    after_acl="yes"
  fi
  after_repr_ok="$after_probe acl=$after_acl"
  bridge_isolation_v2_reapply_record_action \
    "$actions_file" "$path" "v3_channel_dotenv" \
    "$before_repr" "$after_repr_ok" "ok"
  return 0
}

# ---------------------------------------------------------------------------
# 3. per-agent walker
# ---------------------------------------------------------------------------

bridge_isolation_v3_channel_dotenv_migrate_agent() {
  # Walk one agent's 5 channel state dirs × file-type list. Each present
  # target dotenv/state file gets an assert call. Missing dirs are
  # silently skipped (an agent that has not set up Telegram has no
  # workdir/.telegram/ — that's expected steady state, not drift).
  local mode="$1"
  local apply="$2"
  local actions_file="$3"
  local errors_file="$4"
  local agent="$5"

  local os_user agent_grp agent_workdir
  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
  if [[ -z "$agent_grp" ]]; then
    # Fallback to the literal prefix when the canonical helper is
    # unavailable (e.g. partial load order). Matches the prefix the
    # canonical helper uses for the common case.
    agent_grp="${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}${agent}"
  fi
  agent_workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"

  if [[ -z "$os_user" || -z "$agent_workdir" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "agent:$agent" "v3_resolve" "unknown" \
      "os_user+workdir" "error:resolve_failed"
    printf 'cannot resolve os_user or workdir for agent %s\n' "$agent" >> "$errors_file"
    return 1
  fi

  local expected_og="$os_user:$agent_grp"
  local provider state_dir
  local -a per_provider_files

  for provider in discord telegram teams ms365 mattermost; do
    state_dir="$agent_workdir/.$provider"
    [[ -d "$state_dir" ]] || continue

    # Per-provider file list:
    #   - `.env` and `access.json` are common to all providers (when
    #     present); `state.json` exists only for the teams plugin;
    #     `mcp.json` exists only for the mattermost plugin.
    # Missing entries inside an existing state_dir are silently
    # ok:absent in the asserter.
    per_provider_files=(".env" "access.json")
    case "$provider" in
      teams) per_provider_files+=("state.json") ;;
      mattermost) per_provider_files+=("mcp.json") ;;
    esac

    local file
    for file in "${per_provider_files[@]}"; do
      bridge_isolation_v3_channel_dotenv_assert_path \
        "$mode" "$apply" "$actions_file" "$errors_file" \
        "$state_dir/$file" "$expected_og" "0600"
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# 4. emit helpers — text + JSON
# ---------------------------------------------------------------------------

bridge_isolation_v3_channel_dotenv_emit_text() {
  # Human-readable report. One row per action: action, status, before
  # -> after, [path]. Mirrors the v2 reapply text shape so operators
  # can pipe v3 output through the same downstream tooling.
  local actions_file="$1"
  local errors_file="$2"
  local mode="$3"

  printf '== isolation-v3 channel-dotenv migrate (mode=%s) ==\n' "$mode"

  if [[ ! -s "$actions_file" ]]; then
    printf '  (no actions recorded)\n'
    if [[ -s "$errors_file" ]]; then
      printf '  errors:\n'
      sed 's/^/    - /' "$errors_file"
    fi
    return 0
  fi

  local row_path row_action row_before row_after row_status
  local total=0 ok=0 already=0 drift=0 would=0 errors=0
  while IFS=$'\t' read -r row_path row_action row_before row_after row_status; do
    [[ -n "$row_path" ]] || continue
    total=$((total + 1))
    case "$row_status" in
      ok) ok=$((ok + 1)) ;;
      ok:already-canonical) already=$((already + 1)) ;;
      ok:absent) ;;
      drift) drift=$((drift + 1)) ;;
      would) would=$((would + 1)) ;;
      error:*) errors=$((errors + 1)) ;;
    esac
    printf '  %-22s %-22s %s -> %s [%s]\n' \
      "$row_action" "$row_status" "$row_before" "$row_after" "$row_path"
  done < "$actions_file"

  if [[ -s "$errors_file" ]]; then
    printf '  errors:\n'
    sed 's/^/    - /' "$errors_file"
  fi

  printf '\nsummary: total=%d ok=%d already-canonical=%d drift=%d would=%d errors=%d mode=%s\n' \
    "$total" "$ok" "$already" "$drift" "$would" "$errors" "$mode"
}

# Embedded Python for the JSON emitter — kept in a single-quoted shell
# variable and invoked via `python3 -c "$VAR" ...`. That form is
# heredoc-free and here-string-free (footgun #11 / #800 class — see
# lib/bridge-core.sh:9-20 for the canonical rationale). Reads the
# actions/errors files from disk, emits the brief-mandated schema:
#   { "mode": "...", "rows": [{path,action,before,after,status}, ...],
#     "errors": ["...", ...] }
_BRIDGE_ISOLATION_V3_CHANNEL_DOTENV_JSON_PY='
import json
import sys
from pathlib import Path

mode = sys.argv[1]
actions_path = Path(sys.argv[2])
errors_path = Path(sys.argv[3])

rows = []
if actions_path.exists():
    for line in actions_path.read_text().splitlines():
        if not line:
            continue
        cols = line.split("\t")
        while len(cols) < 5:
            cols.append("")
        path, action, before, after, status = cols[:5]
        rows.append({
            "path": path,
            "action": action,
            "before": before,
            "after": after,
            "status": status,
        })

errors = []
if errors_path.exists():
    errors = [ln for ln in errors_path.read_text().splitlines() if ln]

print(json.dumps({
    "mode": mode,
    "rows": rows,
    "errors": errors,
}, indent=2))
'

bridge_isolation_v3_channel_dotenv_emit_json() {
  # JSON report. Schema:
  #   { "mode": "...", "rows": [ {path,action,before,after,status}, ... ],
  #     "errors": [ "...", ... ] }
  local actions_file="$1"
  local errors_file="$2"
  local mode="$3"

  bridge_require_python
  python3 -c "$_BRIDGE_ISOLATION_V3_CHANNEL_DOTENV_JSON_PY" \
    "$mode" "$actions_file" "$errors_file"
}

# ---------------------------------------------------------------------------
# 5. CLI dispatch
# ---------------------------------------------------------------------------

# Usage text — single-quoted shell variable, emitted via printf. No
# heredoc, no here-string (footgun #11 / #800 class).
_BRIDGE_ISOLATION_V3_CHANNEL_DOTENV_USAGE='Usage: agent-bridge migrate isolation v3 [--check|--dry-run|--apply] [--agent <name>] [--json]

Migrate channel dotenv files (under <workdir>/.{discord,telegram,teams,
ms365,mattermost}/) to the v0.13.4 contract: owner=isolated-UID, group=
ab-agent-<slug>, mode=0600, no extended ACL.

Modes (default: --dry-run, NEVER mutates without explicit --apply):
  --check     drift detection only
  --dry-run   plan; emit `would` rows describing mutations
  --apply     perform mutations (requires root or passwordless sudo)

  --agent <name>   scope to one agent (default: every isolated agent)
  --json           emit JSON instead of human text

Notes:
  - macOS / non-Linux hosts silently no-op (no isolated UID concept).
  - Idempotent: a re-run on a migrated tree emits `ok:already-canonical`
    rows and performs no filesystem mutation.
'

bridge_isolation_v3_channel_dotenv_cli() {
  # Default mode: dry-run. Operator MUST opt into --apply explicitly.
  local mode="dry-run"
  local apply="0"
  local single_agent=""
  local emit_json="0"
  local mode_explicit="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        [[ "$mode_explicit" == "0" ]] || bridge_die "migrate isolation v3: --check/--dry-run/--apply are mutually exclusive"
        mode="check"; apply="0"; mode_explicit="1"; shift
        ;;
      --dry-run)
        [[ "$mode_explicit" == "0" ]] || bridge_die "migrate isolation v3: --check/--dry-run/--apply are mutually exclusive"
        mode="dry-run"; apply="0"; mode_explicit="1"; shift
        ;;
      --apply)
        [[ "$mode_explicit" == "0" ]] || bridge_die "migrate isolation v3: --check/--dry-run/--apply are mutually exclusive"
        mode="apply"; apply="1"; mode_explicit="1"; shift
        ;;
      --agent)
        [[ $# -ge 2 ]] || bridge_die "migrate isolation v3: --agent requires a value"
        single_agent="$2"; shift 2
        ;;
      --json) emit_json="1"; shift ;;
      -h|--help|help)
        printf '%s' "$_BRIDGE_ISOLATION_V3_CHANNEL_DOTENV_USAGE"
        return 0
        ;;
      *) bridge_die "migrate isolation v3: unknown option: $1" ;;
    esac
  done

  # macOS / non-Linux: contract no-op. linux-user isolation is Linux-only
  # (no setfacl, no foreign UIDs); emitting JSON or text on those hosts
  # misleads operators into thinking something happened.
  if [[ "$(uname -s 2>/dev/null || printf 'unknown')" != "Linux" ]]; then
    return 0
  fi

  local actions_file errors_file
  actions_file="$(mktemp "${TMPDIR:-/tmp}/agb-isolation-v3-actions.XXXXXX")" \
    || bridge_die "migrate isolation v3: cannot create temp actions file"
  errors_file="$(mktemp "${TMPDIR:-/tmp}/agb-isolation-v3-errors.XXXXXX")" \
    || bridge_die "migrate isolation v3: cannot create temp errors file"
  # shellcheck disable=SC2064
  trap "rm -f '$actions_file' '$errors_file'" RETURN

  # Build the agent list.
  local -a target_agents=()
  if [[ -n "$single_agent" ]]; then
    if [[ "$(bridge_agent_isolation_mode "$single_agent" 2>/dev/null || printf '')" != "linux-user" ]]; then
      bridge_die "migrate isolation v3: agent '$single_agent' is not linux-user-isolated (or not in the roster)"
    fi
    target_agents=("$single_agent")
  else
    local _line
    while IFS= read -r _line; do
      [[ -n "$_line" ]] || continue
      target_agents+=("$_line")
    done < <(bridge_isolation_v3_channel_dotenv_eligible_agents)
  fi

  local agent
  for agent in "${target_agents[@]}"; do
    [[ -n "$agent" ]] || continue
    bridge_isolation_v3_channel_dotenv_migrate_agent \
      "$mode" "$apply" "$actions_file" "$errors_file" "$agent" || true
  done

  if [[ "$emit_json" == "1" ]]; then
    bridge_isolation_v3_channel_dotenv_emit_json \
      "$actions_file" "$errors_file" "$mode"
  else
    bridge_isolation_v3_channel_dotenv_emit_text \
      "$actions_file" "$errors_file" "$mode"
  fi

  # Non-empty errors file → non-zero rc (mirrors v2 reapply behavior).
  if [[ -s "$errors_file" ]]; then
    return 1
  fi
  return 0
}
