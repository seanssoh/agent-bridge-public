#!/usr/bin/env bash
# bridge-plugins.sh — operator commands for the v2 shared plugin catalog.
#
# `seed` populates `$BRIDGE_SHARED_ROOT/plugins-cache/` on a fresh v2
# install by running the de-facto seed helper (`bridge-dev-plugin-cache.py
# sync`) against the in-repo `agent-bridge` marketplace, then applying the
# canonical shared-cache ownership/modes (controller:ab-shared, 2750
# dirs, 0640 files).
#
# Without this, `agb agent create --isolate` on a plugin: channel agent
# bridge_die's with "isolation v2 plugin catalog: $BRIDGE_SHARED_ROOT/
# plugins-cache is not populated" (lib/bridge-agents.sh) — the original
# remediation pointed at `agb bundle install` which has never existed
# (`agb bundle` only has `create|show`). See umbrella #1078 F1.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  # printf-based usage to avoid `cat <<EOF` (footgun #11 — heredoc to a
  # subprocess). Each printf line ends with \n; backslashes inside
  # `\$BRIDGE_*` etc. are preserved by the %s placeholder.
  local prog
  prog="$(basename "$0")"
  printf 'Usage:\n'
  printf '  %s seed [--marketplace-root <path>] [--channels <csv>] [--dry-run]\n' "$prog"
  printf '  %s show [--json]\n' "$prog"
  printf '\n'
  printf 'Seed populates the v2 shared plugin catalog at\n'
  printf '$BRIDGE_SHARED_ROOT/plugins-cache/ from the in-repo agent-bridge\n'
  printf 'marketplace (or --marketplace-root <path> for an external marketplace).\n'
  printf '\n'
  printf 'Show prints the resolved shared-catalog state (root path, populated\n'
  printf 'status, manifest plugin count).\n'
  printf '\n'
  printf 'Requires BRIDGE_LAYOUT=v2 with BRIDGE_DATA_ROOT + BRIDGE_SHARED_ROOT\n'
  printf 'resolved by the layout resolver.\n'
  printf '\n'
  printf 'Examples:\n'
  printf '  # Fresh v2 install — seed the bundled agent-bridge marketplace\n'
  printf '  %s seed\n' "$prog"
  printf '\n'
  printf '  # Seed a specific subset of plugins\n'
  printf '  %s seed --channels plugin:teams@agent-bridge,plugin:ms365@agent-bridge\n' "$prog"
  printf '\n'
  printf '  # Inspect current shared-catalog state\n'
  printf '  %s show --json\n' "$prog"
}

bridge_plugins_require_v2() {
  if ! bridge_isolation_v2_active 2>/dev/null; then
    bridge_die "agb plugins requires BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT (current layout: ${BRIDGE_LAYOUT:-unset}). Run \`agent-bridge upgrade --apply\` or set both env vars before invoking this command."
  fi
  if [[ -z "${BRIDGE_SHARED_ROOT:-}" ]]; then
    bridge_die "agb plugins: BRIDGE_SHARED_ROOT is empty after v2 resolution. This indicates a broken layout marker — run \`agent-bridge doctor\` for diagnostics."
  fi
}

bridge_plugins_default_marketplace_root() {
  # The in-repo agent-bridge marketplace lives next to this script.
  # `.claude-plugin/marketplace.json` is the canonical manifest the
  # sync helper reads.
  printf '%s' "$SCRIPT_DIR"
}

bridge_plugins_default_channels_csv() {
  # Enumerate every plugin in the in-repo marketplace.json as
  # `plugin:<name>@agent-bridge`. We use python3 because it is already a
  # hard dependency (bridge_require_python is called below).
  local mkt_root="$1"
  local mkt_json="$mkt_root/.claude-plugin/marketplace.json"
  [[ -f "$mkt_json" ]] || {
    bridge_warn "agb plugins seed: marketplace.json not found at $mkt_json"
    return 1
  }
  # File-as-argv per footgun #11 (no heredoc-stdin to a subprocess);
  # see lib/upgrade-helpers/plugins-seed-derive-channels.py.
  python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-seed-derive-channels.py" "$mkt_json"
}

bridge_plugins_apply_canonical_modes() {
  # Apply shared-cache ownership/modes per the v2 matrix's
  # `shared-plugins-cache` row: controller:ab-shared, dirs 2750, files
  # 0640. Idempotent — re-running on an already-correct tree is a no-op.
  #
  # This is the post-seed step: bridge-dev-plugin-cache.py creates
  # entries under whatever umask is in effect (usually controller-private
  # 0700/0600). Isolated UIDs need group r-x on every dir + group r on
  # files to traverse and read the catalog, otherwise the share helper
  # in lib/bridge-agents.sh fails its symlink-target reads.
  local plugins_cache="$1"
  [[ -d "$plugins_cache" ]] || {
    bridge_warn "apply_canonical_modes: plugins-cache dir missing: $plugins_cache"
    return 1
  }
  local shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  local controller=""
  controller="$(bridge_isolation_v2_controller_user 2>/dev/null || true)"
  [[ -n "$controller" ]] || {
    bridge_warn "apply_canonical_modes: cannot resolve controller user"
    return 1
  }
  # The chgrp_setgid_dir helper handles the platform discriminator
  # (no-op on macOS, real on Linux) plus direct-first/sudo fallback.
  bridge_isolation_v2_chgrp_setgid_dir "$shared_grp" 2750 "$plugins_cache" \
    || bridge_warn "apply_canonical_modes: chgrp_setgid_dir failed for $plugins_cache"
  # Recurse into subtrees (marketplaces/, cache/) with the same
  # contract. The recursive helper enforces 2750/0640 across dirs and
  # files respectively.
  bridge_isolation_v2_chgrp_setgid_recursive "$shared_grp" 2750 0640 "$plugins_cache" \
    || bridge_warn "apply_canonical_modes: chgrp_setgid_recursive failed for $plugins_cache"
}

bridge_plugins_cmd_seed() {
  bridge_plugins_require_v2
  bridge_require_python

  local marketplace_root=""
  local channels_csv=""
  local dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --marketplace-root)
        [[ $# -ge 2 ]] || bridge_die "--marketplace-root requires a value"
        marketplace_root="$2"
        shift 2
        ;;
      --channels)
        [[ $# -ge 2 ]] || bridge_die "--channels requires a value"
        channels_csv="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 plugins seed 옵션입니다: $1"
        ;;
    esac
  done

  [[ -n "$marketplace_root" ]] || marketplace_root="$(bridge_plugins_default_marketplace_root)"
  if [[ ! -f "$marketplace_root/.claude-plugin/marketplace.json" ]]; then
    bridge_die "agb plugins seed: marketplace.json not found at $marketplace_root/.claude-plugin/marketplace.json. Pass --marketplace-root <path> to an Agent Bridge-format plugin marketplace."
  fi
  if [[ -z "$channels_csv" ]]; then
    channels_csv="$(bridge_plugins_default_channels_csv "$marketplace_root")" \
      || bridge_die "agb plugins seed: failed to enumerate channels from $marketplace_root"
    [[ -n "$channels_csv" ]] || bridge_die "agb plugins seed: marketplace at $marketplace_root contains no plugins"
  fi

  local plugins_cache="$BRIDGE_SHARED_ROOT/plugins-cache"
  local cache_root="$plugins_cache/cache"

  if (( dry_run == 1 )); then
    printf 'agb plugins seed (dry-run):\n'
    printf '  marketplace_root = %s\n' "$marketplace_root"
    printf '  channels         = %s\n' "$channels_csv"
    printf '  plugins_cache    = %s\n' "$plugins_cache"
    printf '  shared_group     = %s\n' "${BRIDGE_SHARED_GROUP:-ab-shared}"
    return 0
  fi

  # mkdir -p $plugins_cache and the cache subtree up front — the sync
  # helper assumes these exist and silently materializes them under the
  # caller's umask otherwise. Pre-creating lets us apply the canonical
  # ownership/modes before any plugin-cache write lands inside.
  _bridge_isolation_v2_run_root_or_sudo mkdir -p "$plugins_cache" "$cache_root" \
    || bridge_die "agb plugins seed: mkdir -p $plugins_cache failed"

  # Apply ownership/modes BEFORE the sync so per-plugin writes inherit
  # the setgid group via the parent dir.
  bridge_plugins_apply_canonical_modes "$plugins_cache" || true

  # Run the sync helper. BRIDGE_CLAUDE_PLUGINS_ROOT pins the manifest
  # location; BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT pins the cache subtree.
  # We treat every channel as channel-required because seed is an
  # explicit operator action — a missing/broken plugin source should
  # fail loud, not warn-and-continue.
  local rc=0
  local output=""
  output="$(BRIDGE_CLAUDE_PLUGINS_ROOT="$plugins_cache" \
            BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$cache_root" \
            python3 "$SCRIPT_DIR/bridge-dev-plugin-cache.py" sync \
              --channels "$channels_csv" \
              --required-channels "$channels_csv" \
              --root "$marketplace_root" \
              --agent "seed" \
              2>&1)" || rc=$?

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi

  # Re-apply canonical modes after the sync so any per-plugin dirs the
  # helper materialized pick up the setgid + group contract.
  bridge_plugins_apply_canonical_modes "$plugins_cache" || true

  if (( rc != 0 )); then
    bridge_die "agb plugins seed: bridge-dev-plugin-cache.py sync failed (rc=$rc). See output above for per-plugin status."
  fi

  if [[ ! -f "$plugins_cache/installed_plugins.json" ]]; then
    bridge_die "agb plugins seed: sync completed but $plugins_cache/installed_plugins.json was not written. This usually means every channel was filtered out (check --channels CSV) or the marketplace at $marketplace_root has no resolvable plugins."
  fi

  printf '[ok] seeded %s (installed_plugins.json present)\n' "$plugins_cache"
}

bridge_plugins_cmd_show() {
  bridge_plugins_require_v2
  bridge_require_python

  local json_output=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_output=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) bridge_die "지원하지 않는 plugins show 옵션입니다: $1" ;;
    esac
  done

  local plugins_cache="$BRIDGE_SHARED_ROOT/plugins-cache"
  local manifest="$plugins_cache/installed_plugins.json"
  local known="$plugins_cache/known_marketplaces.json"
  local populated="false"
  bridge_isolation_v2_shared_plugins_root_populated 2>/dev/null && populated="true"

  if (( json_output == 1 )); then
    # File-as-argv per footgun #11; see lib/upgrade-helpers/plugins-show-json.py.
    python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-show-json.py" \
      "$plugins_cache" "$manifest" "$known" "$populated"
    return 0
  fi

  printf 'plugins_cache: %s\n' "$plugins_cache"
  printf 'populated: %s\n' "$populated"
  if [[ -f "$manifest" ]]; then
    printf 'installed_plugins.json: %s\n' "$manifest"
    local count=""
    count="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('plugins') or {}))" "$manifest" 2>/dev/null || printf 'unknown')"
    printf 'plugin_count: %s\n' "$count"
  else
    printf 'installed_plugins.json: <missing>\n'
  fi
  if [[ -f "$known" ]]; then
    printf 'known_marketplaces.json: %s\n' "$known"
  else
    printf 'known_marketplaces.json: <missing>\n'
  fi
}

case "${1:-}" in
  ""|-h|--help|help)
    usage
    [[ "${1:-}" == "" ]] && exit 1
    exit 0
    ;;
  seed)
    shift
    bridge_plugins_cmd_seed "$@"
    ;;
  show)
    shift
    bridge_plugins_cmd_show "$@"
    ;;
  *)
    bridge_warn "지원하지 않는 plugins 명령입니다: $1"
    usage
    exit 2
    ;;
esac
