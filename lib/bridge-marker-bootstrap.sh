#!/usr/bin/env bash
# bridge-marker-bootstrap.sh — Read v2 layout marker
# (BRIDGE_LAYOUT/BRIDGE_DATA_ROOT) from $BRIDGE_LAYOUT_MARKER_DIR/layout-marker.sh
# with strict validation, before bridge-isolation-v2.sh snapshots those env
# vars. Sourced from bridge-lib.sh after bridge-core.sh (so bridge_warn is
# available) and before bridge-isolation-v2.sh.
#
# Marker location is anchored on BRIDGE_LAYOUT_MARKER_DIR (default
# $BRIDGE_HOME/state), never on BRIDGE_STATE_DIR. v2 activation may move
# controller state to $BRIDGE_DATA_ROOT/state in a future PR, but the marker
# must remain discoverable from a stable location across that change.
#
# Validation:
#   - regular file, not symlink
#   - owner is root (UID 0) or current controller (caller's UID)
#   - mode has no group/world write bits
#   - content lines match an allowlist of KEY=value assignments
#   - when BRIDGE_LAYOUT=v2, BRIDGE_DATA_ROOT must be absolute non-empty
#
# Failures fall back silently to legacy (BRIDGE_LAYOUT defaults to "legacy"
# in bridge-isolation-v2.sh). bridge_warn surfaces the reason once per
# process so operators can investigate.
# shellcheck shell=bash disable=SC2034

bridge_isolation_v2_marker_path() {
  # Marker is anchored on BRIDGE_LAYOUT_MARKER_DIR, never BRIDGE_STATE_DIR.
  # Falls back through env vars so isolated tempdir tests and child processes
  # without bridge-lib.sh sourced still resolve a sensible default.
  printf '%s/layout-marker.sh' \
    "${BRIDGE_LAYOUT_MARKER_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

bridge_isolation_v2_marker_validate() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1

  local owner_uid mode_oct mode_int
  owner_uid="$(stat -c '%u' "$path" 2>/dev/null)"
  if [[ -z "$owner_uid" ]]; then
    return 1
  fi
  if (( owner_uid != 0 )); then
    local controller_uid
    controller_uid="$(id -u 2>/dev/null || true)"
    if [[ -z "$controller_uid" || "$owner_uid" != "$controller_uid" ]]; then
      bridge_warn "layout-marker.sh ignored: owner UID $owner_uid is neither root nor current controller"
      return 1
    fi
  fi

  mode_oct="$(stat -c '%a' "$path" 2>/dev/null)"
  if [[ -z "$mode_oct" ]]; then
    return 1
  fi
  mode_int=$(( 8#$mode_oct ))
  if (( mode_int & 0022 )); then
    bridge_warn "layout-marker.sh ignored: mode $mode_oct has group or world write bit"
    return 1
  fi

  local allowed_re='^(BRIDGE_LAYOUT|BRIDGE_DATA_ROOT|BRIDGE_SHARED_GROUP|BRIDGE_CONTROLLER_GROUP|BRIDGE_AGENT_GROUP_PREFIX)=.*$'
  local line key raw value saw_layout=0 layout_value="" data_root_value=""
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$line" =~ $allowed_re ]]; then
      bridge_warn "layout-marker.sh ignored: disallowed line '$line'"
      return 1
    fi
    key="${line%%=*}"
    raw="${line#*=}"
    if ! bridge_isolation_v2_marker_value_safe "$raw"; then
      bridge_warn "layout-marker.sh ignored: unsafe value for $key"
      return 1
    fi
    value="$(bridge_isolation_v2_marker_value_unquote "$raw")"
    case "$key" in
      BRIDGE_LAYOUT) saw_layout=1; layout_value="$value" ;;
      BRIDGE_DATA_ROOT) data_root_value="$value" ;;
    esac
  done < "$path"

  if (( saw_layout == 1 )) && [[ "$layout_value" == "v2" ]]; then
    if [[ -z "$data_root_value" || "${data_root_value:0:1}" != "/" ]]; then
      bridge_warn "layout-marker.sh ignored: BRIDGE_DATA_ROOT must be absolute, got '$data_root_value'"
      return 1
    fi
  fi

  return 0
}

bridge_isolation_v2_marker_value_safe() {
  # Strict value grammar. Reject any value that could trigger shell
  # expansion (command/process/arithmetic substitution, backticks,
  # redirect/pipe metacharacters, escapes, newlines, or globs) so the
  # marker can never run code via the eventual export. Allowed forms:
  #   - bare token: [A-Za-z0-9_./@:+-]+
  #   - single-quoted token: '<bare token>' or empty ''
  #   - double-quoted token: same content set
  # Anything else is rejected.
  local v="$1"
  case "$v" in
    *'$('*|*'$<'*|*'$>'*|*'$['*|*'$\\'*|*'`'*|*';'*|*'&'*|*'|'* \
      |*'>'*|*'<'*|*'\\'*|*$'\n'*|*$'\r'*|*'*'*|*'?'*|*'~'* )
      return 1
      ;;
  esac
  if [[ "$v" =~ ^\'[A-Za-z0-9_./@:+-]*\'$ ]]; then
    return 0
  fi
  if [[ "$v" =~ ^\"[A-Za-z0-9_./@:+-]*\"$ ]]; then
    return 0
  fi
  if [[ "$v" =~ ^[A-Za-z0-9_./@:+-]+$ ]]; then
    return 0
  fi
  return 1
}

bridge_isolation_v2_marker_value_unquote() {
  local v="$1"
  v="${v#\'}"; v="${v%\'}"
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "$v"
}

bridge_isolation_v2_marker_load() {
  # Parse-and-export, do NOT source the marker. Sourcing would let any
  # validated KEY=value line execute its value (e.g. command substitution),
  # which the validator above explicitly cannot detect on shell-quoted
  # bytes alone.
  local path
  path="$(bridge_isolation_v2_marker_path)"
  [[ -f "$path" ]] || return 0
  bridge_isolation_v2_marker_validate "$path" || return 0

  local line key raw value
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    raw="${line#*=}"
    value="$(bridge_isolation_v2_marker_value_unquote "$raw")"
    case "$key" in
      BRIDGE_LAYOUT) export BRIDGE_LAYOUT="$value" ;;
      BRIDGE_DATA_ROOT) export BRIDGE_DATA_ROOT="$value" ;;
      BRIDGE_SHARED_GROUP) export BRIDGE_SHARED_GROUP="$value" ;;
      BRIDGE_CONTROLLER_GROUP) export BRIDGE_CONTROLLER_GROUP="$value" ;;
      BRIDGE_AGENT_GROUP_PREFIX) export BRIDGE_AGENT_GROUP_PREFIX="$value" ;;
    esac
  done < "$path"
}

# NOTE: marker_load is no longer auto-invoked at source time. The layout
# resolver (lib/bridge-layout-resolver.sh) calls it explicitly after caller
# env validation so it can distinguish env-overrides from marker-loaded
# values. Auto-loading here would race with the resolver's source-attribution
# logic and surface marker-loaded layouts as source=env.
