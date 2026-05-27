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
# only against named files (never `<<<` here-string).

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

if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
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

# v2_agent_group <agent> — returns ab-agent-<slug>. Mirrors
# bridge_isolation_v2_agent_group_name's canonicalization rule
# (lowercase + `-` for `_`). Conservative: keep alnum + `-` only.
v2_agent_group() {
  local a="$1"
  local norm
  norm="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  norm="$(printf '%s' "$norm" | tr -cd 'a-z0-9-')"
  printf 'ab-agent-%s' "$norm"
}

# iso_user_for_agent <agent> — agent-bridge-<slug> (same canonical rule).
iso_user_for_agent() {
  local a="$1"
  local norm
  norm="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  norm="$(printf '%s' "$norm" | tr -cd 'a-z0-9-')"
  printf 'agent-bridge-%s' "$norm"
}

# resolve_agent_home <iso_user> — getent passwd lookup for HOME.
resolve_agent_home() {
  local u="$1"
  local pw
  pw="$(getent passwd "$u" 2>/dev/null || true)"
  [[ -n "$pw" ]] || return 1
  printf '%s\n' "$pw" | awk -F: '{print $6}'
}

# resolve_agent_workdir <agent> — read from the live runtime. Best
# effort; fall back to the canonical layout.
resolve_agent_workdir() {
  local agent="$1"
  local bridge_home="${BRIDGE_HOME:-${HOME}/.agent-bridge}"
  # Lane A (#1213) canonical iso v2 path:
  # ~awfmanager/.agent-bridge/data/agents/<agent>/workdir
  local controller_data="$bridge_home/data/agents/$agent/workdir"
  if sudo -n test -d "$controller_data" 2>/dev/null; then
    printf '%s' "$controller_data"
    return 0
  fi
  # Legacy fallback: shared mode runs under the controller's home.
  local legacy="$bridge_home/agents/$agent/workdir"
  if sudo -n test -d "$legacy" 2>/dev/null; then
    printf '%s' "$legacy"
    return 0
  fi
  return 1
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

  # ------ workdir + channel state dirs ------
  if [[ -n "$workdir" ]]; then
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
        local env_file="$cdir/.env"
        if sudo -n test -e "$env_file" 2>/dev/null; then
          mode="$(stat_mode "$env_file")"
          owner_group="$(stat_owner_group "$env_file")"
          if [[ "$mode" != "600" ]]; then
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
  # Walk the roster — best-effort. We need to source the live runtime
  # roster, which is at $BRIDGE_HOME/agent-roster.local.sh, fallback to
  # agent-roster.sh in the source tree.
  bridge_home="${BRIDGE_HOME:-${HOME}/.agent-bridge}"
  roster_file=""
  if [[ -f "$bridge_home/agent-roster.local.sh" ]]; then
    roster_file="$bridge_home/agent-roster.local.sh"
  elif [[ -f "$REPO_ROOT/agent-roster.sh" ]]; then
    roster_file="$REPO_ROOT/agent-roster.sh"
  fi
  if [[ -z "$roster_file" ]]; then
    die "--all requested but no roster file resolved (looked at $bridge_home/agent-roster.local.sh and $REPO_ROOT/agent-roster.sh)"
  fi
  # Extract agent names — names appear as "AGENT_NAMES+=(<name>)" or
  # "bridge_register_agent <name> ...". Use a defensive grep that
  # accepts both shapes.
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(grep -hE '^[[:space:]]*(bridge_register_agent|AGENT_NAMES\+=)' "$roster_file" 2>/dev/null \
    | sed -E 's/^[[:space:]]*bridge_register_agent[[:space:]]+([A-Za-z0-9_-]+).*/\1/; s/^[[:space:]]*AGENT_NAMES\+=\(([A-Za-z0-9_-]+)\).*/\1/' \
    | sort -u || true)
  if (( ${#agents[@]} == 0 )); then
    printf '# audit: no agents found in roster %s\n' "$roster_file" >&2
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
