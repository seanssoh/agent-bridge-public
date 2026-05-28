#!/usr/bin/env bash
# scripts/audit/iso-v2-ownership-audit.sh — iso v2 ownership/mode audit.
#
# Inspects an isolated agent's workdir + home subtree on a Linux host and
# verifies every file/dir's ownership and mode against the v2 contract.
# Outputs violations in TSV (path / actual / expected / kind) so an
# operator can pipe the result into `sudo chown` / `sudo chmod` fixups.
#
# This is a Lane H (v0.15.0-beta4) deliverable for the iso v2 ownership
# audit family (#1278 + #1208 + #1215 + adjacent). It is a static-source
# audit on a live install — NOT a smoke. The smoke
# `scripts/smoke/H-beta4-iso-ownership.sh` exercises the source patches
# that close this family; this script is what an operator runs against a
# real install to confirm OOTB health.
#
# Expected contract per file/dir family (Linux + iso v2 only):
#
#   workdir/                         iso UID:ab-agent-<a>    2770
#   workdir/.discord/                iso UID:ab-agent-<a>    2770
#   workdir/.telegram/               iso UID:ab-agent-<a>    2770
#   workdir/.teams/                  iso UID:ab-agent-<a>    2770
#   workdir/.ms365/                  iso UID:ab-agent-<a>    2770
#   workdir/.mattermost/             iso UID:ab-agent-<a>    2770
#   workdir/.{channel}/.env          iso UID:ab-agent-<a>    0600
#   home/.claude/plugins/                                    2770 root:ab-agent-<a>  (matrix row "isolated-plugin-manifests")
#   home/.claude/plugins/known_marketplaces.json        iso UID:ab-agent-<a>  0660  (#1278)
#   home/.claude/plugins/known_marketplaces.json.lock   root:ab-agent-<a>     0660  (#1208 — group-writable flock sidecar)
#   home/.claude/plugins/installed_plugins.json         root:ab-agent-<a>     0640
#   home/.claude/plugins/installed_plugins.json.lock    root:ab-agent-<a>     0660  (#1208 — group-writable flock sidecar)
#
# Usage:
#   sudo bash scripts/audit/iso-v2-ownership-audit.sh <agent-name>
#   sudo bash scripts/audit/iso-v2-ownership-audit.sh --all      # walk roster
#
# Output: TSV to stdout, one row per violation:
#   <path>\t<actual-owner>\t<actual-group>\t<actual-mode>\t<expected>\t<kind>
#
# Exit codes:
#   0  — no violations
#   1  — one or more violations found
#   2  — usage / setup error (agent missing, not on Linux, no sudo, ...)
#
# Footgun #11: no heredoc-stdin to a subprocess. All embedded python is
# file-as-argv via mktemp helpers, and shell output uses pipe-to-while
# only against named files (never `<<<` here-string, never `done < <(...)`
# process substitution).

set -uo pipefail

SCRIPT_NAME="iso-v2-ownership-audit"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# Allow callers to override the source root via env (mirror of the
# `BRIDGE_ROSTER_FILE` / `BRIDGE_STATE_DIR` pattern); default to the
# resolved repo root above. This makes the audit usable against a
# secondary checkout when AGENT_BRIDGE_SOURCE_DIR is exported.
if [[ -n "${AGENT_BRIDGE_SOURCE_DIR:-}" && -d "${AGENT_BRIDGE_SOURCE_DIR}" ]]; then
  REPO_ROOT="${AGENT_BRIDGE_SOURCE_DIR}"
fi

# Source bridge-lib.sh so the canonical identity + roster helpers
# (`bridge_isolation_v2_agent_group_name`, `bridge_agent_os_user`,
# `bridge_agent_default_os_user`, `bridge_load_roster`, plus the
# `BRIDGE_AGENT_IDS` / `BRIDGE_AGENT_OS_USER` arrays) are available.
# Codex r1 BLOCKING: the prior r1 derived identities inline (lowercase +
# underscore→hyphen + char-strip) and disagreed with the canonical
# helpers — false skips on `h_smoke` (underscore preserved by canonical)
# and false violations on agents that hash-truncate past Linux's
# 32-char groupadd limit. Source-the-canonical-helpers is the only way
# to guarantee the audit and the runtime use the same identity rules.
if [[ ! -f "$REPO_ROOT/bridge-lib.sh" ]]; then
  printf 'audit: cannot locate bridge-lib.sh under %s (set AGENT_BRIDGE_SOURCE_DIR or run from the source checkout)\n' "$REPO_ROOT" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh"

# Initialize the roster assoc arrays (BRIDGE_AGENT_WORKDIR,
# BRIDGE_AGENT_OS_USER, etc.) so `set -uo pipefail` later in this script
# doesn't trip on `${BRIDGE_AGENT_WORKDIR[$agent]-}` inside
# `bridge_agent_workdir`. bridge-agents.sh's `declare -g -A` lines live
# inside a heredoc (lib/bridge-agents.sh:3450+) and are emitted to the
# runtime env file at agent-write time, NOT executed at source time, so
# the arrays are undeclared until `bridge_reset_roster_maps` runs.
# That helper is the canonical roster-init entry point and is
# idempotent (unset → re-declare).
if declare -F bridge_reset_roster_maps >/dev/null 2>&1; then
  bridge_reset_roster_maps
fi

usage() {
  cat <<'EOF'
Usage:
  iso-v2-ownership-audit.sh <agent-name>
  iso-v2-ownership-audit.sh --all

Inspects an isolated agent's home + workdir tree on a Linux host and
emits TSV rows for ownership / mode violations of the v2 contract.

Expected contract:
  workdir/                          iso UID : ab-agent-<a>  2770
  workdir/.<channel>/               iso UID : ab-agent-<a>  2770
  workdir/.<channel>/.env           iso UID : ab-agent-<a>  0600
  home/.claude/plugins/             root    : ab-agent-<a>  2770
  home/.claude/plugins/known_marketplaces.json   iso UID:ab-agent-<a>  0660  (#1278)
  home/.claude/plugins/known_marketplaces.json.lock  root:ab-agent-<a>  0660  (#1208)
  home/.claude/plugins/installed_plugins.json   root:ab-agent-<a>  0640
  home/.claude/plugins/installed_plugins.json.lock  root:ab-agent-<a>  0660  (#1208)

Exit codes: 0 OK, 1 violations found, 2 usage error.
EOF
}

die() {
  printf 'audit: %s\n' "$*" >&2
  exit 2
}

if [[ "$(uname -s 2>/dev/null)" != "Linux" && -z "${BRIDGE_AUDIT_TEST_FORCE_LINUX:-}" ]]; then
  printf 'audit: skipping — Linux only (iso v2 contract is Linux-specific)\n' >&2
  exit 0
fi

ARG="${1:-}"
case "$ARG" in
  ''|-h|--help) usage; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# stat_mode <path> — prints octal mode (e.g. "2770" or "0660"). Empty on
# error. Linux-only (stat -c).
stat_mode() {
  local p="$1"
  sudo -n stat -c '%a' "$p" 2>/dev/null || true
}

# stat_owner <path> — owner:group form ("root:ab-agent-foo"). Empty on
# error.
stat_owner_group() {
  local p="$1"
  sudo -n stat -c '%U:%G' "$p" 2>/dev/null || true
}

# emit_row <path> <actual-owner-group> <actual-mode> <expected> <kind>
# Reports a violation in TSV.
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

# v2_agent_group <agent> — canonical group name via the same helper the
# v2 grant/check paths use (lib/bridge-isolation-v2.sh:406). Handles
# underscore-bearing agent names, custom `BRIDGE_AGENT_GROUP_PREFIX`,
# and the Linux 32-char hash-truncation policy.
v2_agent_group() {
  bridge_isolation_v2_agent_group_name "$1"
}

# iso_user_for_agent <agent> — canonical iso UID via roster lookup first,
# falling back to `bridge_agent_default_os_user` (lib/bridge-agents.sh:990)
# when the roster has no explicit per-agent value. The roster path picks
# up `--os-user manual` overrides (bridge-agent.sh:3000-3002/3259) without
# this script having to re-implement the operator-override rule.
iso_user_for_agent() {
  local a="$1"
  local user
  user="$(bridge_agent_os_user "$a" 2>/dev/null || printf '')"
  if [[ -n "$user" ]]; then
    printf '%s' "$user"
    return 0
  fi
  bridge_agent_default_os_user "$a"
}

# resolve_agent_home <iso_user> — getent passwd lookup for HOME.
resolve_agent_home() {
  local u="$1"
  local pw
  pw="$(getent passwd "$u" 2>/dev/null || true)"
  [[ -n "$pw" ]] || return 1
  printf '%s\n' "$pw" | awk -F: '{print $6}'
}

# resolve_agent_workdir <agent> — canonical resolver. Codex r2 BLOCKING:
# the prior r2 hardcoded `$BRIDGE_HOME/data/agents/$agent/workdir` instead
# of going through `bridge_agent_workdir` (lib/bridge-agents.sh:5050).
# That helper is what the runtime itself uses, and it honors:
#
#   * `BRIDGE_AGENT_WORKDIR[<agent>]` explicit override (static roster)
#   * `BRIDGE_AGENT_ROOT_V2/<agent>/workdir` when isolation is linux-user
#   * shared-mode dynamic agents' captured cwd
#   * the `bridge_agent_isolation_mode` branch added in v0.13.10 (#895)
#
# Using anything else risks the audit walking the wrong path on agents
# with custom workdirs (static rosters), shared-mode dynamic agents, or
# operator hosts where `BRIDGE_DATA_ROOT` was relocated.
resolve_agent_workdir() {
  local agent="$1"
  local resolved
  resolved="$(bridge_agent_workdir "$agent" 2>/dev/null || printf '')"
  if [[ -z "$resolved" ]]; then
    return 1
  fi
  # sudo -n test handles the case where the audit runs as the controller
  # but the workdir is iso-UID-owned with 2770/group-traversal only.
  if ! sudo -n test -d "$resolved" 2>/dev/null; then
    return 1
  fi
  printf '%s' "$resolved"
}

# ---------------------------------------------------------------------------
# Per-agent audit
# ---------------------------------------------------------------------------

audit_agent() {
  local agent="$1"
  local violations=0

  local iso_user agent_group home workdir
  iso_user="$(iso_user_for_agent "$agent")"
  agent_group="$(v2_agent_group "$agent")"

  # Verify the iso user actually exists; otherwise skip with a notice.
  if ! getent passwd "$iso_user" >/dev/null 2>&1; then
    printf '# audit: skipping agent "%s" — iso user "%s" not provisioned (shared-mode or stale roster entry)\n' \
      "$agent" "$iso_user" >&2
    return 0
  fi

  home="$(resolve_agent_home "$iso_user")" || {
    printf '# audit: cannot resolve HOME for iso user %s\n' "$iso_user" >&2
    return 1
  }

  workdir="$(resolve_agent_workdir "$agent")" || workdir=""

  # ------ home/.claude/plugins/ tree ------
  local plugins_dir="$home/.claude/plugins"
  if sudo -n test -d "$plugins_dir" 2>/dev/null; then
    # Per-UID plugins root: matrix expects root:ab-agent-<a> 2770.
    local mode owner_group
    mode="$(stat_mode "$plugins_dir")"
    owner_group="$(stat_owner_group "$plugins_dir")"
    if [[ "$mode" != "2770" || "$owner_group" != "root:$agent_group" ]]; then
      emit_row "$plugins_dir" "$owner_group" "$mode" "root:$agent_group 2770" "plugins-dir"
      violations=$((violations + 1))
    fi

    # known_marketplaces.json: iso UID:ab-agent-<a> 0660 (#1278).
    local known="$plugins_dir/known_marketplaces.json"
    if sudo -n test -e "$known" 2>/dev/null; then
      mode="$(stat_mode "$known")"
      owner_group="$(stat_owner_group "$known")"
      if [[ "$mode" != "660" || "$owner_group" != "$iso_user:$agent_group" ]]; then
        emit_row "$known" "$owner_group" "$mode" "$iso_user:$agent_group 0660" "known-marketplaces-json"
        violations=$((violations + 1))
      fi
    fi

    # known_marketplaces.json.lock: root:ab-agent-<a> 0660 (#1208).
    local known_lock="$plugins_dir/known_marketplaces.json.lock"
    if sudo -n test -e "$known_lock" 2>/dev/null; then
      mode="$(stat_mode "$known_lock")"
      owner_group="$(stat_owner_group "$known_lock")"
      # owner can be root (controller-created) OR iso UID (iso-created);
      # group MUST be ab-agent-<a> and mode MUST be 0660 so both writers
      # can flock it.
      if [[ "$mode" != "660" ]]; then
        emit_row "$known_lock" "$owner_group" "$mode" "*:$agent_group 0660" "known-marketplaces-lock"
        violations=$((violations + 1))
      elif [[ "$owner_group" != "root:$agent_group" && "$owner_group" != "$iso_user:$agent_group" ]]; then
        emit_row "$known_lock" "$owner_group" "$mode" "root:$agent_group 0660 (or iso UID:group 0660)" "known-marketplaces-lock"
        violations=$((violations + 1))
      fi
    fi

    # installed_plugins.json: root:ab-agent-<a> 0640.
    local installed="$plugins_dir/installed_plugins.json"
    if sudo -n test -e "$installed" 2>/dev/null; then
      mode="$(stat_mode "$installed")"
      owner_group="$(stat_owner_group "$installed")"
      if [[ "$mode" != "640" || "$owner_group" != "root:$agent_group" ]]; then
        emit_row "$installed" "$owner_group" "$mode" "root:$agent_group 0640" "installed-plugins-json"
        violations=$((violations + 1))
      fi
    fi

    # installed_plugins.json.lock: root:ab-agent-<a> 0660 (#1208).
    local installed_lock="$plugins_dir/installed_plugins.json.lock"
    if sudo -n test -e "$installed_lock" 2>/dev/null; then
      mode="$(stat_mode "$installed_lock")"
      owner_group="$(stat_owner_group "$installed_lock")"
      if [[ "$mode" != "660" ]]; then
        emit_row "$installed_lock" "$owner_group" "$mode" "*:$agent_group 0660" "installed-plugins-lock"
        violations=$((violations + 1))
      elif [[ "$owner_group" != "root:$agent_group" && "$owner_group" != "$iso_user:$agent_group" ]]; then
        emit_row "$installed_lock" "$owner_group" "$mode" "root:$agent_group 0660 (or iso UID:group 0660)" "installed-plugins-lock"
        violations=$((violations + 1))
      fi
    fi
  fi

  # ------ workdir root + channel state dirs ------
  if [[ -n "$workdir" ]]; then
    # Codex r2 BLOCKING: validate the workdir root itself BEFORE walking
    # channel children. The v2 writer (lib/bridge-isolation-v2.sh, ASCII
    # layout @ lines 50-51) emits the root as
    # `agent-bridge-<name>:ab-agent-<name> 2770`. If the root is wrong-
    # owner/wrong-group/wrong-mode, every traversal beneath it is broken
    # and the prior audit silently reported "OK". Triple-check
    # (owner+group+mode) just like every other stat in this function.
    local root_mode root_owner_group
    if ! sudo -n test -d "$workdir" 2>/dev/null; then
      emit_row "$workdir" "MISSING" "MISSING" "$iso_user:$agent_group 2770" "workdir-root"
      violations=$((violations + 1))
    else
      root_mode="$(stat_mode "$workdir")"
      root_owner_group="$(stat_owner_group "$workdir")"
      # Accept 2770 (canonical) or 2750 (controller-only-traversal — still
      # valid because the iso UID owns the root with rwx). Reject anything
      # else, including 0700 / 0770 (no setgid) and root:wrong 0700.
      if [[ "$root_mode" != "2770" && "$root_mode" != "2750" ]]; then
        emit_row "$workdir" "$root_owner_group" "$root_mode" "$iso_user:$agent_group 2770" "workdir-root"
        violations=$((violations + 1))
      elif [[ "$root_owner_group" != "$iso_user:$agent_group" ]]; then
        emit_row "$workdir" "$root_owner_group" "$root_mode" "$iso_user:$agent_group 2770" "workdir-root"
        violations=$((violations + 1))
      fi
    fi

    local channel
    for channel in .discord .telegram .teams .ms365 .mattermost; do
      local cdir="$workdir/$channel"
      if sudo -n test -d "$cdir" 2>/dev/null; then
        local mode owner_group
        mode="$(stat_mode "$cdir")"
        owner_group="$(stat_owner_group "$cdir")"
        # #1215: must have x bit (traversal). Accept 2770 (canonical) or
        # 2750 (legacy controller-only-traversal — also fine since the
        # iso UID is the owner with rwx).
        if [[ "$mode" != "2770" && "$mode" != "2750" ]]; then
          emit_row "$cdir" "$owner_group" "$mode" "$iso_user:$agent_group 2770" "channel-state-dir"
          violations=$((violations + 1))
        elif [[ "$owner_group" != "$iso_user:$agent_group" ]]; then
          emit_row "$cdir" "$owner_group" "$mode" "$iso_user:$agent_group 2770" "channel-state-dir"
          violations=$((violations + 1))
        fi
        # .env file: 0600 owned by iso UID (secret file mode contract).
        # Codex r2 BLOCKING: the prior r2 only compared `mode != 600` and
        # never checked owner/group. A root:wrong 0600 .env reported OK,
        # even though the emit-row text would have advertised
        # `$iso_user:$agent_group 0600` — a silent contract violation that
        # ships secret-reading rights to the wrong UID. Triple-check
        # (owner+group+mode) to match the rest of the audit.
        local env_file="$cdir/.env"
        if sudo -n test -e "$env_file" 2>/dev/null; then
          mode="$(stat_mode "$env_file")"
          owner_group="$(stat_owner_group "$env_file")"
          if [[ "$mode" != "600" || "$owner_group" != "$iso_user:$agent_group" ]]; then
            emit_row "$env_file" "$owner_group" "$mode" "$iso_user:$agent_group 0600" "channel-env-file"
            violations=$((violations + 1))
          fi
        fi
      fi
    done
  fi

  if (( violations > 0 )); then
    printf '# audit: agent "%s" — %d violation(s) found\n' "$agent" "$violations" >&2
    return 1
  fi
  printf '# audit: agent "%s" — OK\n' "$agent" >&2
  return 0
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

declare -a agents=()

if [[ "$ARG" == "--all" ]]; then
  # Codex r1 BLOCKING: the prior r1 grepped for `bridge_register_agent` /
  # `AGENT_NAMES+=` patterns that do not exist anywhere in the current
  # source. Live rosters populate `BRIDGE_AGENT_IDS` via the canonical
  # `bridge_add_agent_id_if_missing` registration helper
  # (lib/bridge-core.sh:928), which `bridge_load_roster`
  # (lib/bridge-state.sh:1024) drives by sourcing both the public roster
  # and the protected `agent-roster.local.sh`. Reading the array after
  # the loader returns is the only source-of-truth that matches the
  # runtime's view of the roster — anything else risks the silent-no-op
  # mode codex flagged on the live install.
  bridge_load_roster

  if ! declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    die "--all requested but BRIDGE_AGENT_IDS not declared after bridge_load_roster (bridge-lib.sh source path broken?)"
  fi

  _iter_agent=""
  for _iter_agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$_iter_agent" ]] || continue
    agents+=("$_iter_agent")
  done
  unset _iter_agent

  if (( ${#agents[@]} == 0 )); then
    printf '# audit: no agents found in roster (BRIDGE_AGENT_IDS empty after bridge_load_roster — set BRIDGE_HOME?)\n' >&2
    exit 0
  fi
else
  agents=("$ARG")
fi

total_violations=0
for agent in "${agents[@]}"; do
  if ! audit_agent "$agent"; then
    total_violations=$((total_violations + 1))
  fi
done

if (( total_violations > 0 )); then
  printf '# audit: %d agent(s) have violations\n' "$total_violations" >&2
  exit 1
fi
exit 0
