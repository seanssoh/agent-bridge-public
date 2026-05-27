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
  printf '  %s seed [--marketplace-root <path>] [--channels <csv>] [--dry-run] [--no-iso-chmod] [--no-auto-install]\n' "$prog"
  printf '  %s add-marketplace <repo-url-or-path> [--channels <csv>] [--no-iso-chmod] [--no-auto-install]\n' "$prog"
  printf '  %s show [--json]\n' "$prog"
  printf '  %s list [--json]\n' "$prog"
  printf '  %s marketplaces [--json]\n' "$prog"
  printf '  %s help [install]\n' "$prog"
  printf '\n'
  printf 'Seed populates the v2 shared plugin catalog at\n'
  printf '$BRIDGE_SHARED_ROOT/plugins-cache/ from the in-repo agent-bridge\n'
  printf 'marketplace (or --marketplace-root <path> for an external marketplace).\n'
  printf '\n'
  printf 'Add-marketplace is an integrated verb that clones (URL) or\n'
  printf 'registers (path) an external marketplace, runs seed, and applies\n'
  printf 'the iso v2 shared-cache chmod (mode 2770 + chgrp ab-shared). One\n'
  printf 'command replaces the 5-step claude+agb dance for iso v2 agents.\n'
  printf '\n'
  printf 'Show prints the resolved shared-catalog state (root path, populated\n'
  printf 'status, manifest plugin count).\n'
  printf '\n'
  printf 'List enumerates installed plugins from\n'
  printf '$BRIDGE_SHARED_ROOT/plugins-cache/installed_plugins.json\n'
  printf '(name@marketplace, version, install path). Empty catalog → empty list.\n'
  printf '\n'
  printf 'Marketplaces enumerates known marketplaces from\n'
  printf '$BRIDGE_SHARED_ROOT/plugins-cache/known_marketplaces.json\n'
  printf '(id, source.kind, source.path). Empty catalog → empty list.\n'
  printf '\n'
  printf 'Help renders an advisory for `claude plugin install` users (the\n'
  printf 'controller-side install does NOT propagate to iso v2 agents — use\n'
  printf '`agb plugins seed` or `agb plugins add-marketplace` to mirror).\n'
  printf '\n'
  printf '%s\n' '--no-auto-install opts seed/add-marketplace out of the automatic'
  printf '%s\n' '`bun install` pass that resolves a plugin'"'"'s node_modules when its'
  printf '%s\n' 'package.json declares deps but the dir is missing. Use for'
  printf '%s\n' 'air-gapped environments where the operator manages deps manually.'
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
  printf '  # Add a new external marketplace (clone+register+seed+chmod)\n'
  printf '  %s add-marketplace https://github.com/me/my-marketplace --channels plugin:cosmax-crm,plugin:cosmax-ep-approval\n' "$prog"
  printf '  %s add-marketplace /path/to/local/marketplace\n' "$prog"
  printf '\n'
  printf '  # Inspect current shared-catalog state\n'
  printf '  %s show --json\n' "$prog"
  printf '\n'
  printf '  # Enumerate installed plugins / known marketplaces\n'
  printf '  %s list --json\n' "$prog"
  printf '  %s marketplaces --json\n' "$prog"
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
  local no_iso_chmod=0
  local no_auto_install=0
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
      --no-iso-chmod)
        # L1-F (beta20): skip the o+rX recursive grant on the marketplace
        # source dir. Operators with a read-only mount or who want to
        # manage UID visibility manually pass this; the iso UID side
        # then needs an alternative read path (named-user ACL or a
        # symlink under $BRIDGE_HOME/plugins owned by the controller).
        no_iso_chmod=1
        shift
        ;;
      --no-auto-install)
        # #1250 (beta3): opt out of the automatic `bun install` pass that
        # resolves a plugin's node_modules when its package.json declares
        # deps but node_modules is missing. Air-gapped environments
        # where the operator pre-stages node_modules out-of-band use
        # this flag. When set, a missing node_modules + declared deps
        # still produces seed_status=incomplete on channel-required
        # plugins (fail-loud), but the auto-install step is skipped.
        no_auto_install=1
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
  # Canonicalize so downstream propagation (controller registry +
  # per-iso-UID known_marketplaces.json) writes a stable absolute path
  # — Claude's marketplace resolver compares strings, not realpath, so
  # `/tmp/foo` and `/tmp/./foo` would round-trip differently.
  local _marketplace_root_resolved=""
  if _marketplace_root_resolved="$(cd -P "$marketplace_root" 2>/dev/null && pwd -P)" \
      && [[ -n "$_marketplace_root_resolved" ]]; then
    marketplace_root="$_marketplace_root_resolved"
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
    printf '  no_iso_chmod     = %s\n' "$no_iso_chmod"
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

  # ----- #1250 (beta3): node_modules auto-install --------------------------
  # The sync output enumerates per-plugin status lines that include
  # `node_modules=<status>` + `criticality=<channel-required|optional>`.
  # When a plugin declares deps (package.json with `dependencies` /
  # `peerDependencies`, or a bun.lock / package-lock.json present) but
  # node_modules is missing, the sync silently leaves the cache in an
  # incomplete state — operators see a passing seed but the iso UID's
  # MCP spawn fails at first start with "Cannot find module ...".
  #
  # Default behavior: run `bun install` (or `npm install` fallback) in the
  # plugin's SOURCE dir, then re-run the sync for the affected channels
  # so the cache picks up the freshly-installed node_modules. Failure
  # mode: fail-loud (bridge_die) when any channel-required plugin still
  # has node_modules=missing after the install pass; warn + continue
  # for criticality=optional. --no-auto-install opts out entirely.
  if (( no_auto_install == 0 )); then
    local _auto_install_rc=0
    bridge_plugins_seed_auto_install_node_modules \
      "$marketplace_root" "$plugins_cache" "$cache_root" "$channels_csv" \
      "$output" \
      || _auto_install_rc=$?
    if (( _auto_install_rc != 0 )); then
      # codex r1 BLOCKING: emit summary structured token BEFORE die so
      # operators + CI grep see the contract documented in the smoke
      # B-beta3-1249-1250-plugin-ux.sh header (seed_status=incomplete +
      # node_modules=install_failed + criticality=channel-required).
      # The inner function already emitted per-plugin tokens; this is
      # the aggregate summary at the wrapper die-site.
      _bridge_plugins_emit_seed_failure_tokens "auto-install" "channel-required" "$_auto_install_rc"
      bridge_die "agb plugins seed: node_modules auto-install pass failed — see output above. Re-run with --no-auto-install to skip the auto-install step (operator must then resolve deps manually), or fix the underlying error (bun not on PATH, dep resolution failure, missing lockfile) and re-run."
    fi
  else
    # When --no-auto-install is set, still fail-loud on channel-required
    # plugins whose node_modules is missing — operators must know about
    # the gap. The check parses the same sync output.
    local _no_auto_rc=0
    bridge_plugins_seed_check_no_auto_install_gap "$output" \
      || _no_auto_rc=$?
    if (( _no_auto_rc != 0 )); then
      # codex r1 BLOCKING (mirror): the --no-auto-install gap path is
      # the same fail-loud contract — emit structured tokens before
      # die. The inner check itself does not have per-plugin context
      # at this layer; the aggregate summary suffices.
      _bridge_plugins_emit_seed_failure_tokens "no-auto-install-gap" "channel-required" "$_no_auto_rc"
      bridge_die "agb plugins seed: --no-auto-install set, but one or more channel-required plugins have node_modules=missing. See output above. Resolve manually (e.g. \`cd <plugin_dir> && bun install\`) then re-run \`agb plugins seed --marketplace-root $marketplace_root\`."
    fi
  fi

  # ----- L1 wave 2 propagation steps (beta20, 2026-05-25) -----

  # Resolve marketplace name for the propagation steps. Both controller
  # registry add (D1) and per-iso-UID merge (D2) key off the name field
  # from marketplace.json — keep it as a single source of truth.
  local _seed_mkt_name=""
  _seed_mkt_name="$(python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-seed-marketplace-name.py" \
                    "$marketplace_root/.claude-plugin/marketplace.json" 2>/dev/null || printf '')"

  # D1 (L1-A): propagate the marketplace to the controller's claude
  # registry. Without this, `claude plugin install --scope user <spec>`
  # in the launcher path needs a manual `claude plugin marketplace add`
  # before it can resolve `<plugin>@<marketplace>`. We do the same
  # already in `bridge_ensure_agent_bridge_claude_marketplace` for the
  # bundled marketplace, but only on-demand when an agent's launch
  # path hits a plugin: channel. Seeding should propagate up-front so
  # an `agent start` on a fresh install does NOT spawn the slow
  # marketplace-add side trip.
  bridge_plugins_seed_propagate_controller_registry "$marketplace_root" "$_seed_mkt_name" \
    || bridge_warn "[plugins seed] controller claude-registry propagation: non-fatal failure (continuing)"

  # D4 (#1201): mirror the external marketplace tree into
  # $plugins_cache/marketplaces/<id>/ so the iso UID's
  # `~/.claude/plugins/marketplaces/<id>` symlink target exists.
  # Without this, `bridge_known_marketplace_info` (lib/bridge-agents.sh:1664)
  # skips the marketplace because the controller-side
  # `<plugins_root>/marketplaces/<id>` mirror is absent, and the warning
  # planted at lib/bridge-agents.sh:2884 fires at every `agent create`.
  # Bundled `agent-bridge` is intentionally skipped: the install-tree
  # reconciler already covers the bundled marketplace via the
  # `installLocation`/`source.path` fallback at lib/bridge-agents.sh:2006-2013.
  #
  # codex r2 BLOCKING 1: helper failure on a non-bundled external
  # marketplace is FATAL. Without the mirror, the downstream
  # `bridge_known_marketplace_info` lookup at iso prep / start time
  # fails the "directory != agent-bridge → skip" guard at
  # lib/bridge-agents.sh:1843-1844, every `agent create` warns
  # "no controller-side mirror exists", and the iso agent launches
  # with a missing marketplace symlink. We must NOT continue to
  # D3/D2 propagation in that case — D2 in particular writes the
  # mirror path into per-UID `known_marketplaces.json`, and that
  # would point at a non-existent dir.
  #
  # The mirror helper short-circuits with rc=0 for the bundled
  # `agent-bridge` marketplace, so callers seeding the bundled
  # marketplace never enter this fatal branch.
  if ! bridge_plugins_seed_mirror_marketplace_root \
        "$marketplace_root" "$_seed_mkt_name" "$plugins_cache"; then
    bridge_die "agb plugins seed: marketplace mirror creation failed for '$_seed_mkt_name' under $plugins_cache/marketplaces/. The iso UID's marketplaces/<id> symlink target would be missing, so isolated agents would fail to load plugins from this marketplace. Resolve the underlying error (rsync availability, permissions on $plugins_cache, unsafe marketplace id) and re-run \`agb plugins seed --marketplace-root $marketplace_root\`."
  fi

  # Mirror path that D2/D3 propagation should reference as the
  # controller-stable source for this marketplace. SHOULD-FIX 1 (codex
  # r2): D2 used to pass the original `$marketplace_root` (e.g.
  # `/tmp/pi-registry/`), which the per-UID `known_marketplaces.json`
  # then recorded as `installLocation` / `source.path`. The original
  # tree can disappear (tmp cleanup, repo move) after seed completes;
  # the mirror under `$plugins_cache/marketplaces/<id>` is the
  # controller-stable replacement that survives. For the bundled
  # `agent-bridge` marketplace the helper short-circuited above and
  # the mirror dir does NOT exist — fall back to the original
  # `$marketplace_root` in that case (the existing
  # `installLocation`/`source.path` fallback at
  # lib/bridge-agents.sh:2006-2013 covers the bundled tree).
  local _seed_d2_source_path="$marketplace_root"
  if [[ "$_seed_mkt_name" != "agent-bridge" \
        && -d "$plugins_cache/marketplaces/$_seed_mkt_name" ]]; then
    _seed_d2_source_path="$plugins_cache/marketplaces/$_seed_mkt_name"
  fi

  # D3 (L1-F): external marketplace clones often land at mode 0700
  # (operator umask), which iso UIDs cannot traverse → dev-plugin-cache
  # source-link / read fails. Recursively grant world traverse + read
  # (`o+rX`) so the iso UID can resolve the source path through the
  # known_marketplaces.json entry written by D2. Gated to Linux + iso
  # v2 + path-under-operator-HOME so the helper doesn't widen system
  # directories or no-op-needlessly on macOS dev hosts.
  if (( no_iso_chmod == 0 )); then
    bridge_plugins_seed_external_marketplace_iso_readable "$marketplace_root" \
      || bridge_warn "[plugins seed] external marketplace o+rX grant: non-fatal failure (continuing)"
  else
    bridge_info "[plugins seed] --no-iso-chmod set: skipping recursive o+rX on $marketplace_root (operator-managed)"
  fi

  # D2 (L1-D): propagate the marketplace entry to every linux-user
  # isolated agent's per-UID known_marketplaces.json whose channels
  # reference this marketplace. Without this, `resolve_marketplace_root`
  # in bridge-dev-plugin-cache.py (running under BRIDGE_CLAUDE_PLUGINS_ROOT
  # pointing at the iso HOME) falls back to the bundled agent-bridge
  # marketplace and the plugin install silently mismatches.
  #
  # Pre-existing per-agent isolation prepare ALREADY writes a filtered
  # per-UID catalog (bridge_write_isolated_known_marketplaces_catalog)
  # — but that runs at `agent create --linux-user` time, not at seed
  # time, and it reads from the CONTROLLER's known_marketplaces.json.
  # Seed→per-agent-prepare is the canonical order on a clean install,
  # but on a retrofit (operator runs `agb plugins seed` AFTER the iso
  # agents already exist) the per-UID catalog still lacks the entry.
  # This step covers that retrofit path. The per-agent prepare path
  # remains the canonical writer for fresh agent creation.
  #
  # codex r2 SHOULD-FIX 1: pass the MIRROR path
  # (`$plugins_cache/marketplaces/<id>`) as the propagation source so
  # per-UID `known_marketplaces.json` records a controller-stable
  # location for the marketplace tree. See `_seed_d2_source_path`
  # resolution above.
  bridge_plugins_seed_propagate_iso_known_marketplaces "$_seed_d2_source_path" "$_seed_mkt_name" \
    || bridge_warn "[plugins seed] iso known_marketplaces.json propagation: non-fatal failure (continuing)"

  printf '[ok] seeded %s (installed_plugins.json present)\n' "$plugins_cache"
}

# #1250 (beta3, codex r1 BLOCKING): emit a single structured failure
# token line that operators and CI can grep for. Documented contract in
# the smoke `B-beta3-1249-1250-plugin-ux.sh` header lines 13-17.
# Shape (single line, space-separated tokens):
#   seed_status=incomplete node_modules=install_failed \
#     plugin=<name> criticality=<channel-required|optional> rc=<N>
# Emitted BEFORE every bridge_die in the auto-install pass + caller
# wrapper. The per-plugin loop emits one line per failing plugin; the
# caller die emits a summary line with plugin=<aggregate-or-unknown>.
_bridge_plugins_emit_seed_failure_tokens() {
  local plugin="${1:-unknown}"
  local criticality="${2:-channel-required}"
  local rc="${3:-1}"
  printf '%s\n' \
    "seed_status=incomplete node_modules=install_failed plugin=$plugin criticality=$criticality rc=$rc"
}

# #1250 (beta3): inspect bridge-dev-plugin-cache.py sync output, identify
# plugins whose status verified BUT node_modules=missing AND the plugin
# source declares deps (package.json with dependencies / lockfile), then
# run `bun install` in the source dir, then re-sync the affected channels
# so the cache refresh picks up node_modules.
#
# Args:
#   $1 — marketplace_root (canonicalized absolute path)
#   $2 — plugins_cache ($BRIDGE_SHARED_ROOT/plugins-cache)
#   $3 — cache_root ($plugins_cache/cache)
#   $4 — channels_csv used in the original seed pass
#   $5 — the sync output text (full stdout+stderr) from the first sync
#
# Return: 0 on success (including the no-op case where nothing needs
#         install); non-zero when one or more channel-required plugins
#         still have node_modules=missing after the install pass, or
#         when bun is not on PATH but a channel-required plugin needs
#         install. Caller turns non-zero into `bridge_die`.
bridge_plugins_seed_auto_install_node_modules() {
  local marketplace_root="$1"
  local plugins_cache="$2"
  local cache_root="$3"
  local channels_csv="$4"
  local sync_output="$5"

  local _output_tmp
  _output_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-seed-sync-out.XXXXXX")" \
    || { bridge_warn "[plugins-seed] auto-install: mktemp failed"; return 1; }
  printf '%s' "$sync_output" >"$_output_tmp"

  local _rows_tmp
  _rows_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-seed-needs-install.XXXXXX")" \
    || { rm -f "$_output_tmp"; bridge_warn "[plugins-seed] auto-install: mktemp failed"; return 1; }

  # File-as-argv per footgun #11 — the helper reads the sync output
  # from disk, not stdin. The output is TSV: plugin\tcriticality\tsource\tcache
  if ! python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-seed-parse-sync-output.py" \
        "$_output_tmp" >"$_rows_tmp" 2>/dev/null; then
    bridge_warn "[plugins-seed] auto-install: parser helper failed — skipping auto-install (re-run with --no-auto-install if expected)"
    rm -f "$_output_tmp" "$_rows_tmp" 2>/dev/null || true
    return 0
  fi
  rm -f "$_output_tmp" 2>/dev/null || true

  if [[ ! -s "$_rows_tmp" ]]; then
    # No plugins need install — fast path.
    rm -f "$_rows_tmp" 2>/dev/null || true
    return 0
  fi

  # Resolve bun (or npm fallback). When neither is available and at least
  # one channel-required plugin needs install, fail-loud.
  local bun_bin="" npm_bin=""
  if command -v bridge_resolve_bun_executable >/dev/null 2>&1; then
    bun_bin="$(bridge_resolve_bun_executable 2>/dev/null || true)"
  fi
  if [[ -z "$bun_bin" ]]; then
    bun_bin="$(command -v bun 2>/dev/null || true)"
  fi
  if [[ -z "$bun_bin" ]]; then
    npm_bin="$(command -v npm 2>/dev/null || true)"
  fi

  if [[ -z "$bun_bin" && -z "$npm_bin" ]]; then
    # Anything channel-required → fail. Optional-only → warn + continue.
    local has_required=0
    local _required_plugin=""
    local _row plugin criticality src cache
    while IFS=$'\t' read -r plugin criticality src cache; do
      [[ -n "$plugin" ]] || continue
      if [[ "$criticality" == "channel-required" ]]; then
        has_required=1
        _required_plugin="$plugin"
        break
      fi
    done <"$_rows_tmp"
    if (( has_required == 1 )); then
      bridge_warn "[plugins-seed] auto-install: bun/npm not on PATH but a channel-required plugin needs node_modules. Install bun (curl -fsSL https://bun.sh/install | bash) or pass --no-auto-install."
      # codex r1 BLOCKING: emit structured token before returning 1 so
      # the caller die path sees a greppable line in output too.
      _bridge_plugins_emit_seed_failure_tokens "$_required_plugin" "channel-required" "127"
      rm -f "$_rows_tmp" 2>/dev/null || true
      return 1
    fi
    bridge_warn "[plugins-seed] auto-install: bun/npm not on PATH; skipping install for optional plugins. Re-run with bun installed when you want full deps."
    rm -f "$_rows_tmp" 2>/dev/null || true
    return 0
  fi

  # Run the install pass. Collect the list of affected channels so we
  # can re-sync once afterwards (single re-sync, not per-plugin, to
  # keep the audit log compact and avoid N round-trips into the
  # dev-plugin-cache helper).
  local -a affected_channels=()
  local _row plugin criticality src cache install_rc=0
  local overall_install_failed_required=0
  while IFS=$'\t' read -r plugin criticality src cache; do
    [[ -n "$plugin" ]] || continue
    [[ -d "$src" ]] || {
      bridge_warn "[plugins-seed] auto-install: source dir missing for $plugin: $src — skipping"
      if [[ "$criticality" == "channel-required" ]]; then
        _bridge_plugins_emit_seed_failure_tokens "$plugin" "$criticality" "127"
        overall_install_failed_required=1
      fi
      continue
    }
    bridge_info "[plugins-seed] auto-install: node_modules missing for $plugin (criticality=$criticality); auto-installing via ${bun_bin:+bun}${bun_bin:-${npm_bin:+npm}}"
    install_rc=0
    if [[ -n "$bun_bin" ]]; then
      if [[ -f "$src/bun.lock" || -f "$src/bun.lockb" ]]; then
        ( cd "$src" && "$bun_bin" install --frozen-lockfile --no-summary >&2 ) || install_rc=$?
      else
        ( cd "$src" && "$bun_bin" install --no-summary >&2 ) || install_rc=$?
      fi
    else
      ( cd "$src" && "$npm_bin" install --no-audit --no-fund >&2 ) || install_rc=$?
    fi
    if (( install_rc != 0 )); then
      bridge_warn "[plugins-seed] auto-install: $plugin install failed (rc=$install_rc)"
      # codex r1 BLOCKING: emit structured token BEFORE deciding fail-loud
      # so even optional-failure paths surface a greppable line. The
      # caller wrapper still emits its own summary line at die-time.
      _bridge_plugins_emit_seed_failure_tokens "$plugin" "$criticality" "$install_rc"
      [[ "$criticality" == "channel-required" ]] && overall_install_failed_required=1
      continue
    fi
    # Widen so iso UIDs can read via the controller-side mirror copy.
    chmod -R go+rX "$src/node_modules" 2>/dev/null \
      || bridge_warn "[plugins-seed] auto-install: chmod -R go+rX $src/node_modules failed (non-fatal)"
    # Plugin's matching channel reference uses `<plugin>@<marketplace>`.
    affected_channels+=("$plugin")
  done <"$_rows_tmp"
  rm -f "$_rows_tmp" 2>/dev/null || true

  if (( overall_install_failed_required == 1 )); then
    bridge_warn "[plugins-seed] auto-install: one or more channel-required plugins failed install — pass --no-auto-install to skip, or fix bun/dep resolution and re-run \`agb plugins seed\`."
    return 1
  fi

  if (( ${#affected_channels[@]} == 0 )); then
    # All install attempts failed but they were all optional — non-fatal.
    return 0
  fi

  # Re-sync the channels we just installed. We pass the FULL original
  # channels_csv (not just the affected subset) so the post-sync output
  # remains an accurate snapshot of the whole catalog.
  local _resync_rc=0
  local _resync_output=""
  _resync_output="$(BRIDGE_CLAUDE_PLUGINS_ROOT="$plugins_cache" \
            BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$cache_root" \
            python3 "$SCRIPT_DIR/bridge-dev-plugin-cache.py" sync \
              --channels "$channels_csv" \
              --required-channels "$channels_csv" \
              --root "$marketplace_root" \
              --agent "seed-autoinstall" \
              2>&1)" || _resync_rc=$?
  if [[ -n "$_resync_output" ]]; then
    printf '%s\n' "$_resync_output"
  fi
  if (( _resync_rc != 0 )); then
    bridge_warn "[plugins-seed] auto-install: post-install re-sync failed (rc=$_resync_rc)"
    return 1
  fi

  # Re-apply canonical modes so the freshly-cached node_modules trees
  # land at 2750 dirs / 0640 files under ab-shared.
  bridge_plugins_apply_canonical_modes "$plugins_cache" || true

  # Final verification: parse the re-sync output and confirm no
  # channel-required plugin still reports node_modules=missing with
  # declared deps. Optional plugins that still fail leave a warning but
  # do not turn the overall pass into a failure.
  local _verify_tmp _verify_rows
  _verify_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-seed-verify.XXXXXX")"
  printf '%s' "$_resync_output" >"$_verify_tmp"
  _verify_rows="$(mktemp "${TMPDIR:-/tmp}/agb-seed-verify-rows.XXXXXX")"
  python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-seed-parse-sync-output.py" \
    "$_verify_tmp" >"$_verify_rows" 2>/dev/null || true
  rm -f "$_verify_tmp" 2>/dev/null || true

  local still_failed_required=0
  while IFS=$'\t' read -r plugin criticality src cache; do
    [[ -n "$plugin" ]] || continue
    if [[ "$criticality" == "channel-required" ]]; then
      bridge_warn "[plugins-seed] auto-install: $plugin still reports node_modules=missing after auto-install (seed_status=incomplete)"
      # codex r1 BLOCKING: also emit structured token line for the
      # post-resync still-missing branch so the contract is uniform
      # across all failure paths.
      _bridge_plugins_emit_seed_failure_tokens "$plugin" "$criticality" "1"
      still_failed_required=1
    else
      bridge_warn "[plugins-seed] auto-install: optional plugin $plugin still has node_modules=missing (seed_status=incomplete, criticality=optional — continuing)"
    fi
  done <"$_verify_rows"
  rm -f "$_verify_rows" 2>/dev/null || true

  if (( still_failed_required == 1 )); then
    return 1
  fi
  return 0
}

# #1250 (beta3): when --no-auto-install is set, the operator opted out
# of the install pass. We MUST still fail-loud on a channel-required
# plugin with node_modules=missing — silent ride-through is the bug the
# issue is fixing. Same parser as the auto-install branch; rc=non-zero
# when at least one channel-required row remains.
bridge_plugins_seed_check_no_auto_install_gap() {
  local sync_output="$1"

  local _output_tmp _rows_tmp
  _output_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-seed-noauto-out.XXXXXX")" \
    || { bridge_warn "[plugins-seed] no-auto-install check: mktemp failed"; return 0; }
  printf '%s' "$sync_output" >"$_output_tmp"
  _rows_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-seed-noauto-rows.XXXXXX")" \
    || { rm -f "$_output_tmp"; return 0; }

  if ! python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-seed-parse-sync-output.py" \
        "$_output_tmp" >"$_rows_tmp" 2>/dev/null; then
    rm -f "$_output_tmp" "$_rows_tmp" 2>/dev/null || true
    return 0
  fi
  rm -f "$_output_tmp" 2>/dev/null || true

  local plugin criticality src cache has_required=0
  while IFS=$'\t' read -r plugin criticality src cache; do
    [[ -n "$plugin" ]] || continue
    if [[ "$criticality" == "channel-required" ]]; then
      bridge_warn "[plugins-seed] --no-auto-install: $plugin has node_modules=missing + declared deps (criticality=channel-required, seed_status=incomplete). Resolve manually: cd $src && bun install"
      has_required=1
    fi
  done <"$_rows_tmp"
  rm -f "$_rows_tmp" 2>/dev/null || true

  if (( has_required == 1 )); then
    return 1
  fi
  return 0
}

# D4 (#1201): mirror an external directory-source marketplace tree into
# `$plugins_cache/marketplaces/<marketplace_id>/` so the per-UID
# `marketplaces/<id>` symlink (planted by bridge_linux_share_plugin_catalog
# in lib/bridge-agents.sh:2947-2974) lands on a real source dir. Without
# this, `bridge_known_marketplace_info` (lib/bridge-agents.sh:1664) skips
# every directory-source marketplace other than the bundled `agent-bridge`,
# and `agent create --isolation linux-user` warns that the controller-side
# mirror is missing.
#
# Args:
#   $1 — source marketplace root (canonicalized absolute path); must
#        contain `.claude-plugin/marketplace.json`.
#   $2 — marketplace id (from the manifest's `name` field, already
#        resolved by `bridge_plugins_cmd_seed`).
#   $3 — `$plugins_cache` (`$BRIDGE_SHARED_ROOT/plugins-cache`).
#
# Bundled `agent-bridge` is intentionally NOT mirrored — the existing
# fallback path in `bridge_known_marketplace_info` (line 1838-1844) uses
# the `installLocation`/`source.path` from `known_marketplaces.json` for
# the bundled marketplace only. Mirroring it here would duplicate the
# entire repo on every seed.
#
# Idempotency: rsync without `--delete` so the mirror dir refreshes in
# place. `--delete` is intentionally avoided per codex r1 spec — the iso
# symlinks at `~/.claude/plugins/marketplaces/<id>` point at the mirror
# tree, and a stray `--delete` during a sibling seed could erase files
# the symlinks resolve through. Stale-file risk is acceptable on the
# directory-source path because the seed is operator-driven.
#
# Permissions: after rsync, reuse
# `bridge_plugins_apply_canonical_modes` so dirs end at `2750/ab-shared`
# with setgid, files at `g+rX,g-w,o-rwx`. The controller remains the
# owner; the iso UID reads via group membership (ab-shared).
bridge_plugins_seed_mirror_marketplace_root() {
  local mkt_root="$1"
  local mkt_name="$2"
  local plugins_cache="$3"

  [[ -n "$mkt_root" ]] || {
    bridge_warn "[plugins seed] D4: marketplace_root required"
    return 1
  }
  [[ -n "$mkt_name" ]] || {
    bridge_warn "[plugins seed] D4: marketplace name required (could not resolve from $mkt_root/.claude-plugin/marketplace.json)"
    return 1
  }
  [[ -n "$plugins_cache" ]] || {
    bridge_warn "[plugins seed] D4: plugins_cache required"
    return 1
  }
  [[ -d "$mkt_root" ]] || {
    bridge_warn "[plugins seed] D4: marketplace_root is not a directory: $mkt_root"
    return 1
  }

  # Bundled in-repo marketplace exception. The bundled name is `agent-bridge`
  # in the manifest at `.claude-plugin/marketplace.json` and the existing
  # `bridge_known_marketplace_info` fallback covers its directory-source
  # discovery via `installLocation`/`source.path`. Refuse to walk the
  # entire repo into the mirror tree.
  if [[ "$mkt_name" == "agent-bridge" ]]; then
    bridge_info "[plugins seed] D4: marketplace '$mkt_name' is the bundled in-repo marketplace — relying on existing installLocation fallback (skipping mirror)"
    return 0
  fi

  # Validate the marketplace id with the safe-alias rules. The id becomes
  # the final path component under the controller-owned `marketplaces/`
  # tree; the existing
  # `bridge_isolation_alias_rejection_reason` rejects path-traversal /
  # NUL / reserved-Windows-name / leading-dot etc. The iso symlink planter
  # in lib/bridge-agents.sh:2855 enforces the same rule on the consumer
  # side, but rejecting here keeps the failure local and the error message
  # actionable. Defense in depth.
  if command -v bridge_isolation_alias_rejection_reason >/dev/null 2>&1; then
    local _alias_reason=""
    _alias_reason="$(bridge_isolation_alias_rejection_reason "$mkt_name")"
    if [[ -n "$_alias_reason" ]]; then
      bridge_warn "[plugins seed] D4: refusing to mirror marketplace id '$mkt_name' — $_alias_reason. Rename the marketplace in $mkt_root/.claude-plugin/marketplace.json."
      return 1
    fi
  fi

  local mirror_parent="$plugins_cache/marketplaces"
  local mirror_root="$mirror_parent/$mkt_name"

  # Resolve canonical source to detect the same-source mirror-onto-self
  # case. An operator passing `--marketplace-root $plugins_cache/marketplaces/<id>`
  # (or any path inside it) would otherwise have rsync copy a tree onto
  # itself and either silently succeed with no change or, worse, hit the
  # rsync `source and destination are the same` warning. Skip the mirror
  # in that case — the operator's source IS the mirror.
  local _src_resolved="" _dst_resolved=""
  if _src_resolved="$(cd -P "$mkt_root" 2>/dev/null && pwd -P)"; then
    :
  else
    bridge_warn "[plugins seed] D4: could not canonicalize $mkt_root"
    return 1
  fi
  if [[ -d "$mirror_root" ]]; then
    _dst_resolved="$(cd -P "$mirror_root" 2>/dev/null && pwd -P || printf '')"
  fi
  if [[ -n "$_dst_resolved" && "$_src_resolved" == "$_dst_resolved" ]]; then
    bridge_info "[plugins seed] D4: marketplace_root resolves to mirror destination ($_dst_resolved) — already mirrored, no-op"
    # Re-apply modes idempotently in case ownership/perms drift since
    # the previous seed.
    bridge_plugins_apply_canonical_modes "$plugins_cache" || true
    return 0
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    bridge_warn "[plugins seed] D4: rsync is not installed — refusing to mirror $mkt_root to $mirror_root. Install rsync (apt install rsync / brew install rsync) and re-run \`agb plugins seed\`."
    return 1
  fi

  # Ensure the parent + mirror root exist. The mirror parent
  # ($plugins_cache/marketplaces) inherits the canonical modes from
  # bridge_plugins_apply_canonical_modes after rsync completes; we do not
  # pre-chmod here. mkdir is sudo-aware via the same helper bridge-plugins.sh
  # uses for plugins_cache itself.
  _bridge_isolation_v2_run_root_or_sudo mkdir -p "$mirror_root" \
    || {
      bridge_warn "[plugins seed] D4: mkdir -p $mirror_root failed"
      return 1
    }

  bridge_info "[plugins seed] D4: mirroring $mkt_root → $mirror_root (rsync -a, no --delete)"
  # rsync -a preserves modes/owners where permitted (we'll re-apply
  # canonical modes below regardless). Trailing slash on source =
  # "contents of $mkt_root", paired with absolute $mirror_root as
  # destination. Exclude `.git/` so a git-tracked source checkout does
  # not bloat the mirror. No `--delete` per codex r1 spec.
  local _rsync_rc=0
  _bridge_isolation_v2_run_root_or_sudo rsync -a --exclude=.git/ \
    "$_src_resolved"/ "$mirror_root"/ \
    || _rsync_rc=$?
  if (( _rsync_rc != 0 )); then
    bridge_warn "[plugins seed] D4: rsync from $_src_resolved/ to $mirror_root/ failed (rc=$_rsync_rc)"
    return 1
  fi

  # Re-apply canonical modes across the whole plugins-cache tree so the
  # new mirror subtree picks up 2750 dirs + 0640 files under
  # ab-shared. The existing `bridge_plugins_apply_canonical_modes`
  # walks recursively via `bridge_isolation_v2_chgrp_setgid_recursive`,
  # so we do not need a narrower scope here — the chgrp_setgid_dir +
  # recursive contract already idempotently re-asserts the matrix on
  # every node beneath plugins_cache. On macOS dev hosts both helpers
  # short-circuit via the platform discriminator (no-op).
  bridge_plugins_apply_canonical_modes "$plugins_cache" || true

  return 0
}

# D1 (L1-A): add the marketplace to the controller's claude registry
# at `$HOME/.claude/plugins/known_marketplaces.json`. Idempotent —
# `claude plugin marketplace list` is consulted first to avoid
# duplicate writes.
#
# Args:
#   $1 — marketplace_root (canonicalized absolute path)
#   $2 — marketplace_name (from manifest)
#
# Returns:
#   0 on success or already-present, non-zero if the add failed.
#   Missing `claude` binary returns 0 with a bridge_info note — fresh
#   installs that do not yet have the Claude CLI in PATH should not
#   block the seed.
bridge_plugins_seed_propagate_controller_registry() {
  local mkt_root="$1"
  local mkt_name="$2"

  if ! command -v claude >/dev/null 2>&1; then
    bridge_info "[plugins seed] D1: claude CLI not on PATH — skipping controller-registry add (will lazy-add via bridge_ensure_*_marketplace when an agent's plugin channel fires)"
    return 0
  fi

  if [[ -z "$mkt_name" ]]; then
    bridge_warn "[plugins seed] D1: could not resolve marketplace name from $mkt_root/.claude-plugin/marketplace.json — skipping controller-registry add"
    return 1
  fi

  local list_output=""
  list_output="$(claude plugin marketplace list 2>/dev/null || true)"
  # Word-boundary match (mirrors bridge_claude_marketplace_ensure_present_for_isolated).
  if printf '%s\n' "$list_output" \
      | grep -Eq "(^|[[:space:]])${mkt_name}([[:space:]]|\$)"; then
    bridge_info "[plugins seed] D1: marketplace '$mkt_name' already in controller registry (skipped)"
    return 0
  fi

  bridge_info "[plugins seed] D1: adding marketplace '$mkt_name' to controller registry: $mkt_root"
  if ! claude plugin marketplace add --scope user "$mkt_root" >/dev/null 2>&1; then
    bridge_warn "[plugins seed] D1: \`claude plugin marketplace add --scope user $mkt_root\` failed — agents on this marketplace may need a manual marketplace add before first plugin install"
    return 1
  fi
  return 0
}

# D3 (L1-F): grant world traverse+read recursively on an external
# marketplace clone dir so iso UIDs can read package files via the
# `known_marketplaces.json` directory source pointer.
#
# Gated to Linux + iso v2 active + path under $HOME (operator's home,
# not a system path). On non-Linux hosts and on shared-mode installs
# the grant is a no-op — there is no separate UID to grant to.
#
# Args:
#   $1 — marketplace_root (canonicalized absolute path)
bridge_plugins_seed_external_marketplace_iso_readable() {
  local mkt_root="$1"

  # Linux-only — macOS dev hosts run agents under the operator UID so
  # the read path is already covered.
  if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    return 0
  fi
  # Skip when iso v2 isn't active (shared-mode installs don't need
  # this widening).
  if ! bridge_isolation_v2_active 2>/dev/null; then
    return 0
  fi
  # If the marketplace root IS the bundled in-repo marketplace
  # (`$SCRIPT_DIR`), don't widen it here — the install-tree reconciler
  # already covers `$BRIDGE_HOME/{lib,scripts,hooks,runtime,shared}` and
  # the source checkout is covered by the operator's existing umask
  # plus the matrix's `data-root`/`lib-dir` etc. rows.
  local bundled_root="$SCRIPT_DIR"
  if [[ "$mkt_root" == "$bundled_root" ]]; then
    bridge_info "[plugins seed] D3: marketplace_root == bundled in-repo marketplace ($mkt_root) — install-tree reconciler covers it (skipping recursive o+rX)"
    return 0
  fi
  # Only widen paths under $HOME — refuse to walk system paths so a
  # mistake (e.g. `--marketplace-root /usr`) cannot accidentally widen
  # /usr/local/* or similar.
  local home_dir="${HOME:-}"
  if [[ -z "$home_dir" ]]; then
    bridge_warn "[plugins seed] D3: \$HOME is unset — refusing to widen $mkt_root (caller's HOME must be set for the safety gate)"
    return 1
  fi
  case "$mkt_root" in
    "$home_dir"|"$home_dir"/*)
      :
      ;;
    /tmp/*|/var/tmp/*|/private/tmp/*|/private/var/tmp/*)
      # tmpdirs are operator-writable and frequently used for fixture
      # marketplaces (the brief's `/tmp/cosmax-crm-cli`, `/tmp/pi-registry`,
      # smoke fixtures). Allow.
      :
      ;;
    *)
      bridge_info "[plugins seed] D3: marketplace_root $mkt_root is outside \$HOME and tmpdirs — skipping recursive o+rX (operator must manage read access for iso UIDs manually, or pass --no-iso-chmod and configure named-user ACL)"
      return 0
      ;;
  esac
  if [[ ! -d "$mkt_root" ]]; then
    bridge_warn "[plugins seed] D3: marketplace_root is not a directory: $mkt_root — skipping recursive o+rX"
    return 1
  fi

  bridge_info "[plugins seed] D3: granting recursive o+rX on $mkt_root so iso UIDs can read package files (use --no-iso-chmod to opt out)"
  # `chmod -R o+rX` — POSIX X grants execute only on dirs (preserves
  # the executable bit on files that already have it without
  # promoting every file to executable). No sudo: this is the
  # operator's own tree.
  if ! chmod -R o+rX "$mkt_root" 2>/dev/null; then
    bridge_warn "[plugins seed] D3: \`chmod -R o+rX $mkt_root\` failed — iso UIDs may not be able to read package files. Operator may have a read-only mount; re-run with --no-iso-chmod once an alternative read path (named-user ACL or controller-owned symlink) is configured."
    return 1
  fi
  return 0
}

# D2 (L1-D): write/merge the marketplace entry into each linux-user
# isolated agent's `~/.claude/plugins/known_marketplaces.json` whose
# channels reference this marketplace. Runs as root via
# `bridge_linux_sudo_root` because the destination is under
# `/home/agent-bridge-<a>/` (root-owned with group=ab-agent-<a>).
#
# Args:
#   $1 — marketplace_root (canonicalized absolute path)
#   $2 — marketplace_name (from manifest)
bridge_plugins_seed_propagate_iso_known_marketplaces() {
  local mkt_root="$1"
  local mkt_name="$2"

  if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    return 0
  fi
  if ! bridge_isolation_v2_active 2>/dev/null; then
    return 0
  fi
  if [[ -z "$mkt_name" ]]; then
    bridge_warn "[plugins seed] D2: could not resolve marketplace name from $mkt_root/.claude-plugin/marketplace.json — skipping iso UID propagation"
    return 1
  fi

  # Need the reapply-eligible helper + per-agent shell helpers.
  if ! command -v bridge_isolation_v2_reapply_eligible_agents >/dev/null 2>&1; then
    bridge_info "[plugins seed] D2: bridge_isolation_v2_reapply_eligible_agents not loaded — skipping iso UID propagation (no roster active)"
    return 0
  fi
  if ! command -v bridge_agent_channels_csv >/dev/null 2>&1; then
    bridge_info "[plugins seed] D2: bridge_agent_channels_csv not loaded — skipping iso UID propagation"
    return 0
  fi
  if ! command -v bridge_agent_os_user >/dev/null 2>&1; then
    bridge_info "[plugins seed] D2: bridge_agent_os_user not loaded — skipping iso UID propagation"
    return 0
  fi

  # The seed command does not load the roster eagerly (the sync helper
  # itself does not need per-agent declarations). D2 does — it walks
  # every linux-user iso agent's channel list. Load the roster
  # idempotently here. bridge_load_roster short-circuits on
  # already-loaded state.
  if command -v bridge_load_roster >/dev/null 2>&1; then
    bridge_load_roster >/dev/null 2>&1 || true
  fi

  local eligible=""
  eligible="$(bridge_isolation_v2_reapply_eligible_agents 2>/dev/null || true)"
  if [[ -z "$eligible" ]]; then
    bridge_info "[plugins seed] D2: no linux-user isolated agents in roster — nothing to propagate"
    return 0
  fi

  local agent
  local propagated=0
  local skipped=0
  local failed=0
  # Materialize $eligible to a tmp file so the `while read` consumer
  # avoids `<<<` here-string / `<()` procsub — both rejected by the
  # lint-heredoc-ban ratchet (footgun #11 class). Cleanup after loop.
  local _eligible_stream_tmp
  _eligible_stream_tmp="$(mktemp)" || { bridge_warn "[plugins seed] D2: mktemp failed"; return 1; }
  printf '%s\n' "$eligible" > "$_eligible_stream_tmp"
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    local agent_channels=""
    agent_channels="$(bridge_agent_channels_csv "$agent" 2>/dev/null || printf '')"
    # Only propagate when at least one channel references THIS marketplace.
    if ! _bridge_plugins_seed_channels_csv_uses_marketplace "$agent_channels" "$mkt_name"; then
      ((skipped++)) || true
      continue
    fi

    local os_user=""
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
    if [[ -z "$os_user" ]]; then
      bridge_warn "[plugins seed] D2: agent '$agent' has no os_user resolved — skipping"
      ((failed++)) || true
      continue
    fi

    local user_home=""
    if command -v bridge_agent_linux_user_home >/dev/null 2>&1; then
      user_home="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || printf '')"
    fi
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
      bridge_warn "[plugins seed] D2: agent '$agent' (os_user=$os_user) has no resolvable HOME ($user_home) — skipping"
      ((failed++)) || true
      continue
    fi

    local iso_plugins_dir="$user_home/.claude/plugins"
    if ! bridge_linux_sudo_root test -d "$iso_plugins_dir" 2>/dev/null; then
      bridge_info "[plugins seed] D2: agent '$agent' has no $iso_plugins_dir (iso prep has not run yet) — skipping; next \`agent create\` or reapply will write the catalog"
      ((skipped++)) || true
      continue
    fi

    local iso_known="$iso_plugins_dir/known_marketplaces.json"
    local agent_group=""
    if command -v bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then
      agent_group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
    fi

    # Write the merged catalog via the standalone helper. The helper is
    # idempotent and uses a same-dir temp + os.replace so partial writes
    # never leave a half-merged file. We do the merge from the current
    # iso_known content (if any) → out path = iso_known. Run as root so
    # the file lands at the right owner; chown/chmod follow.
    #
    # Issue #1208: pass BRIDGE_PLUGIN_LOCK_GROUP=$agent_group so the
    # helper's sidecar `known_marketplaces.json.lock` is created (or
    # normalized) as `root:$agent_group 0660` — group-write so the iso
    # UID's `bridge-dev-plugin-cache.py` writer can re-acquire the same
    # flock during `agent start`. Without this, the lock lands as
    # `root:root 0600` and iso UID's plugin cache write fails with
    # EACCES, blocking `agent start` for any iso v2 agent with plugin
    # channels.
    local rc=0
    if ! bridge_linux_sudo_root \
        env "BRIDGE_PLUGIN_LOCK_GROUP=${agent_group:-}" python3 \
        "$SCRIPT_DIR/lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py" \
        "$iso_known" "$iso_known" "$mkt_name" "$mkt_root" >/dev/null 2>&1; then
      rc=$?
      bridge_warn "[plugins seed] D2: merge for agent '$agent' (target=$iso_known) failed with rc=$rc"
      ((failed++)) || true
      continue
    fi
    # root:ab-agent-<a> mode 0640 — matches the contract that
    # bridge_write_isolated_known_marketplaces_catalog applies to
    # the same file on the canonical per-agent prepare path.
    if [[ -n "$agent_group" ]]; then
      bridge_linux_sudo_root chown "root:$agent_group" "$iso_known" >/dev/null 2>&1 \
        || bridge_warn "[plugins seed] D2: chown root:$agent_group $iso_known failed (agent '$agent')"
    else
      bridge_linux_sudo_root chown root:root "$iso_known" >/dev/null 2>&1 || true
    fi
    bridge_linux_sudo_root chmod 0640 "$iso_known" >/dev/null 2>&1 \
      || bridge_warn "[plugins seed] D2: chmod 0640 $iso_known failed (agent '$agent')"

    # Issue #1208 self-heal: normalize any pre-existing lock files
    # owned by `root:root 0600` (left behind by beta24 OOTB installs
    # before this fix landed). The python helper above creates a fresh
    # lock with the right metadata when the env var is set, but a
    # cached lock from an earlier seed run that pre-dates this patch
    # would still be `root:root 0600`. Also normalize
    # `installed_plugins.json.lock` to match the parent contract at
    # `lib/bridge-isolation-v2.sh:1734-1747` (plugin manifest flocks
    # are group-writable).
    if [[ -n "$agent_group" ]]; then
      local iso_known_lock="$iso_plugins_dir/known_marketplaces.json.lock" # noqa: iso-helper-boundary
      local iso_installed_lock="$iso_plugins_dir/installed_plugins.json.lock" # noqa: iso-helper-boundary
      if bridge_linux_sudo_root test -e "$iso_known_lock" 2>/dev/null; then
        bridge_linux_sudo_root chown "root:$agent_group" "$iso_known_lock" \
          >/dev/null 2>&1 \
          || bridge_warn "[plugins seed] D2: chown lock root:$agent_group $iso_known_lock failed (agent '$agent')"
        bridge_linux_sudo_root chmod 0660 "$iso_known_lock" \
          >/dev/null 2>&1 \
          || bridge_warn "[plugins seed] D2: chmod 0660 $iso_known_lock failed (agent '$agent')"
      fi
      if bridge_linux_sudo_root test -e "$iso_installed_lock" 2>/dev/null; then
        bridge_linux_sudo_root chown "root:$agent_group" "$iso_installed_lock" \
          >/dev/null 2>&1 \
          || bridge_warn "[plugins seed] D2: chown lock root:$agent_group $iso_installed_lock failed (agent '$agent')"
        bridge_linux_sudo_root chmod 0660 "$iso_installed_lock" \
          >/dev/null 2>&1 \
          || bridge_warn "[plugins seed] D2: chmod 0660 $iso_installed_lock failed (agent '$agent')"
      fi
    fi

    ((propagated++)) || true
  done < "$_eligible_stream_tmp"
  rm -f "$_eligible_stream_tmp" 2>/dev/null || true

  bridge_info "[plugins seed] D2: propagated=$propagated skipped=$skipped failed=$failed (target marketplace='$mkt_name')"
  if (( failed > 0 )); then
    return 1
  fi
  return 0
}

# Internal: returns 0 if the comma-separated channels list contains at
# least one plugin: channel that references the target marketplace.
_bridge_plugins_seed_channels_csv_uses_marketplace() {
  local csv="${1:-}"
  local mkt="${2:-}"
  [[ -n "$csv" && -n "$mkt" ]] || return 1
  # Split CSV via parameter expansion to avoid `<<<` here-string
  # (footgun #11 class, lint-heredoc-ban ratchet rejects it).
  local -a items=()
  local _csv_rest="$csv"
  while [[ -n "$_csv_rest" ]]; do
    items+=("${_csv_rest%%,*}")
    [[ "$_csv_rest" == *","* ]] || break
    _csv_rest="${_csv_rest#*,}"
  done
  local item plugin_spec marketplace
  for item in "${items[@]}"; do
    # trim whitespace
    item="${item## }"
    item="${item%% }"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    [[ "$plugin_spec" == *@* ]] || continue
    marketplace="${plugin_spec##*@}"
    if [[ "$marketplace" == "$mkt" ]]; then
      return 0
    fi
  done
  return 1
}

bridge_plugins_cmd_list() {
  # Read-only enumeration of installed plugins from the v2 shared
  # plugins-cache manifest. Empty catalog (missing manifest) → empty
  # list, exit 0 — operators querying a freshly-resolved layout
  # before `agb plugins seed` should get an empty list, not an error.
  # `show` continues to be the status / populated-flag surface.
  #
  # Pre-scan for `-h|--help` BEFORE `bridge_plugins_require_v2` so the
  # help contract holds on hosts where v2 has not been resolved yet
  # (mirrors the #1114 fix for daemon verbs — help must never depend
  # on bridge config).
  local _a
  for _a in "$@"; do
    case "$_a" in
      -h|--help) usage; return 0 ;;
    esac
  done

  bridge_plugins_require_v2
  bridge_require_python

  local json_output=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_output=1; shift ;;
      *) bridge_die "지원하지 않는 plugins list 옵션입니다: $1" ;;
    esac
  done

  local plugins_cache="$BRIDGE_SHARED_ROOT/plugins-cache"
  local manifest="$plugins_cache/installed_plugins.json"

  if (( json_output == 1 )); then
    # File-as-argv per footgun #11; see lib/upgrade-helpers/plugins-list-json.py.
    python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-list-json.py" \
      "$plugins_cache" "$manifest"
    return 0
  fi

  printf 'plugins_cache: %s\n' "$plugins_cache"
  if [[ ! -f "$manifest" ]]; then
    printf 'installed_plugins.json: <missing>\n'
    printf 'plugin_count: 0\n'
    return 0
  fi
  printf 'installed_plugins.json: %s\n' "$manifest"
  # Reuse the json helper for the enumeration, then pretty-print via
  # python3 so the human-readable output stays consistent with the
  # JSON shape (id/spec/version/installPath).
  python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-list-json.py" \
    "$plugins_cache" "$manifest" \
    | python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-list-pretty.py"
}

bridge_plugins_cmd_marketplaces() {
  # Read-only enumeration of known marketplaces from the v2 shared
  # plugins-cache catalog. Empty catalog (missing file) → empty list,
  # exit 0. Same operator-affordance as `plugins list`.
  #
  # Pre-scan for `-h|--help` before `bridge_plugins_require_v2` (see
  # comment in bridge_plugins_cmd_list for rationale).
  local _a
  for _a in "$@"; do
    case "$_a" in
      -h|--help) usage; return 0 ;;
    esac
  done

  bridge_plugins_require_v2
  bridge_require_python

  local json_output=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_output=1; shift ;;
      *) bridge_die "지원하지 않는 plugins marketplaces 옵션입니다: $1" ;;
    esac
  done

  local plugins_cache="$BRIDGE_SHARED_ROOT/plugins-cache"
  local known="$plugins_cache/known_marketplaces.json"

  if (( json_output == 1 )); then
    # File-as-argv per footgun #11; see
    # lib/upgrade-helpers/plugins-marketplaces-json.py.
    python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-marketplaces-json.py" \
      "$plugins_cache" "$known"
    return 0
  fi

  printf 'plugins_cache: %s\n' "$plugins_cache"
  if [[ ! -f "$known" ]]; then
    printf 'known_marketplaces.json: <missing>\n'
    printf 'marketplace_count: 0\n'
    return 0
  fi
  printf 'known_marketplaces.json: %s\n' "$known"
  python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-marketplaces-json.py" \
    "$plugins_cache" "$known" \
    | python3 "$SCRIPT_DIR/lib/upgrade-helpers/plugins-marketplaces-pretty.py"
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

# #1249 (beta3): integrated `add-marketplace` verb. Replaces the 5-step
# `claude plugin marketplace add` + `claude plugin install` + manual
# `agb plugins seed` dance for operators provisioning a new marketplace
# on an iso v2 install. Single command:
#
#   1. Resolve <url-or-path> to a directory:
#      - URL (http(s)://, git@, ssh://): clone to a controller-owned dir
#        under $BRIDGE_SHARED_ROOT/plugins-cache/_clones/<safe-id>/ (or
#        re-use existing clone via `git pull --ff-only`).
#      - Local path: canonicalize.
#   2. Verify `.claude-plugin/marketplace.json` exists.
#   3. Delegate to `bridge_plugins_cmd_seed` with `--marketplace-root
#      <resolved>` (and pass-through flags `--channels`, `--no-iso-chmod`,
#      `--no-auto-install`). seed already does the D1/D2/D3/D4
#      propagation, mirror creation, canonical chmod, and `bun install`
#      pass — we just front it with a friendlier "given a URL, do the
#      right thing" verb.
#
# Idempotency: re-running with the same URL refreshes the clone via
# `git pull --ff-only`; re-running with the same path is a no-op clone
# step + identical seed pass (seed is itself idempotent).
bridge_plugins_cmd_add_marketplace() {
  bridge_plugins_require_v2
  bridge_require_python

  local target=""
  local -a seed_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channels)
        [[ $# -ge 2 ]] || bridge_die "--channels requires a value"
        seed_args+=(--channels "$2")
        shift 2
        ;;
      --no-iso-chmod)
        seed_args+=(--no-iso-chmod)
        shift
        ;;
      --no-auto-install)
        seed_args+=(--no-auto-install)
        shift
        ;;
      --dry-run)
        seed_args+=(--dry-run)
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        bridge_die "지원하지 않는 plugins add-marketplace 옵션입니다: $1"
        ;;
      *)
        if [[ -n "$target" ]]; then
          bridge_die "add-marketplace accepts a single positional <url-or-path> (got extra: $1)"
        fi
        target="$1"
        shift
        ;;
    esac
  done

  [[ -n "$target" ]] || bridge_die "add-marketplace requires <repo-url-or-path>. Example: agb plugins add-marketplace https://github.com/me/my-marketplace --channels plugin:my-plugin"

  local resolved_root=""
  # URL pattern detection. Accept http(s)://, ssh://, git@host:owner/repo,
  # and `git+...://` forms.
  case "$target" in
    http://*|https://*|ssh://*|git+*://*|git://*)
      resolved_root="$(bridge_plugins_add_marketplace_clone_url "$target")" \
        || bridge_die "add-marketplace: failed to clone $target"
      ;;
    git@*)
      resolved_root="$(bridge_plugins_add_marketplace_clone_url "$target")" \
        || bridge_die "add-marketplace: failed to clone $target"
      ;;
    *)
      # Path. Refuse on non-existence — operator most likely typo'd the URL.
      if [[ ! -d "$target" ]]; then
        bridge_die "add-marketplace: $target is not an existing directory and does not look like a clonable URL. Pass a URL (http(s)://, ssh://, git@host:owner/repo) or a local marketplace path."
      fi
      resolved_root="$(cd -P "$target" 2>/dev/null && pwd -P)" \
        || bridge_die "add-marketplace: cannot canonicalize $target"
      ;;
  esac

  if [[ ! -f "$resolved_root/.claude-plugin/marketplace.json" ]]; then
    bridge_die "add-marketplace: $resolved_root does not contain .claude-plugin/marketplace.json. The resolved directory must be an Agent Bridge-format plugin marketplace (see docs/plugin-authoring-iso-v2.md)."
  fi

  bridge_info "[plugins add-marketplace] resolved: $resolved_root"
  bridge_info "[plugins add-marketplace] delegating to \`plugins seed --marketplace-root $resolved_root\` ${seed_args[*]}"

  bridge_plugins_cmd_seed --marketplace-root "$resolved_root" "${seed_args[@]}"
}

# #1249 (beta3): URL clone helper. Maintains a controller-owned clone
# directory under $BRIDGE_SHARED_ROOT/plugins-cache/_clones/<safe-id>/.
# Re-clones with `git pull --ff-only` when the dir already exists.
#
# Stdout: the absolute path of the resulting clone dir (single line).
# Return: 0 on success, non-zero on failure (clone or pull error).
bridge_plugins_add_marketplace_clone_url() {
  local url="$1"
  [[ -n "$url" ]] || { bridge_warn "clone_url: empty URL"; return 1; }
  if ! command -v git >/dev/null 2>&1; then
    bridge_warn "clone_url: git not on PATH — cannot clone $url. Install git and retry."
    return 1
  fi

  # Derive a safe id from the URL's last path component (strip .git).
  # `safe-id` ↔ /[A-Za-z0-9._-]+/ — anything else is replaced with `_`.
  local last="${url##*/}"
  last="${last%.git}"
  local safe_id=""
  safe_id="$(printf '%s' "$last" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  [[ -n "$safe_id" ]] || { bridge_warn "clone_url: could not derive safe id from URL $url"; return 1; }

  local clones_parent="$BRIDGE_SHARED_ROOT/plugins-cache/_clones"
  local clone_dir="$clones_parent/$safe_id"

  _bridge_isolation_v2_run_root_or_sudo mkdir -p "$clones_parent" \
    || { bridge_warn "clone_url: mkdir -p $clones_parent failed"; return 1; }

  if [[ -d "$clone_dir/.git" ]]; then
    # Idempotent path — refresh via git pull --ff-only.
    # #1273 defense-in-depth: explicit `>&2` on bridge_info even though
    # bridge_info itself now routes to stderr (lib/bridge-core.sh:412).
    # If a future patch (or a callsite override) restores stdout output,
    # the caller's `resolved_root="$(...)"` capture must NOT pick this
    # diagnostic up as part of the returned path.
    bridge_info "[plugins add-marketplace] clone exists at $clone_dir — refreshing with git pull --ff-only" >&2
    if ! ( cd "$clone_dir" && git pull --ff-only >&2 ); then
      bridge_warn "clone_url: git pull --ff-only in $clone_dir failed — leaving existing clone in place"
      # Non-fatal: existing clone may still be usable. Caller will
      # validate marketplace.json next.
    fi
  else
    bridge_info "[plugins add-marketplace] cloning $url → $clone_dir" >&2
    if ! git clone --depth 1 -- "$url" "$clone_dir" >&2; then
      bridge_warn "clone_url: git clone $url → $clone_dir failed"
      return 1
    fi
  fi

  printf '%s\n' "$clone_dir"
  return 0
}

# #1249 (beta3): `agb plugins help [install]` — informational verb. Prints
# the iso v2 advisory text for operators who just ran (or are about to
# run) `claude plugin install <plugin>@<marketplace>` against a host
# where the bridge owns the plugin catalog. controller-side install does
# NOT propagate to iso v2 agents; operator must run `agb plugins seed`
# or `agb plugins add-marketplace` to mirror.
#
# This is the user-facing surface of the #1249 "banner" requirement.
# A true `claude plugin install` wrapper-hook would require shimming
# Claude Code's CLI; that is out of scope for a single-PR fix. Instead
# we ship the advisory in an `agb plugins help install` page that the
# operator runs (and that `agb plugins` with no args points at via
# the usage block).
bridge_plugins_cmd_help() {
  local topic="${1:-install}"
  case "$topic" in
    install)
      printf '%s\n' \
        "agb plugins — claude plugin install advisory" \
        "" \
        "Note: when running on a host with isolation-v2 agents (linux-user" \
        "isolation enabled at install time), \`claude plugin install" \
        "<plugin>@<marketplace>\` only updates the controller-side Claude" \
        "plugin registry. Iso v2 agents read from the bridge-owned plugin" \
        "catalog at \$BRIDGE_SHARED_ROOT/plugins-cache/ instead, which is" \
        "intentionally separate by design — the iso UID cannot read the" \
        "operator's \$HOME/.claude/plugins/ tree without escalation." \
        "" \
        "To make a plugin available to iso v2 agents you must either:" \
        "" \
        "  agb plugins seed --channels plugin:<name>@<marketplace>" \
        "" \
        "    Re-runs the v2 plugin seed against the bundled or already-" \
        "    registered marketplace, mirrors the plugin into" \
        "    \$BRIDGE_SHARED_ROOT/plugins-cache/, applies the iso v2 ACL" \
        "    chmod (mode 2770 + chgrp ab-shared), and propagates the" \
        "    marketplace entry to every iso UID's known_marketplaces.json." \
        "" \
        "  agb plugins add-marketplace <url-or-path> --channels plugin:<name>" \
        "" \
        "    Integrated verb that clones (URL) or registers (path) a new" \
        "    marketplace + runs the seed in one call. Use this when the" \
        "    plugin lives in a marketplace the bridge has never seen." \
        "" \
        "After either command, restart the iso agent (\`agb agent restart" \
        "<agent>\`) so the v2 plugin loader picks up the new manifest." \
        "" \
        "See: docs/plugin-authoring-iso-v2.md for the full iso v2 plugin" \
        "contract."
      return 0
      ;;
    -h|--help|"")
      usage
      return 0
      ;;
    *)
      printf '%s\n' "Unknown help topic: $topic" >&2
      printf '%s\n' "Available topics: install" >&2
      return 2
      ;;
  esac
}

# Smoke / library callers that want the helpers without dispatching the
# CLI can source this file with `BRIDGE_PLUGINS_LIB_ONLY=1`. The standard
# `agb plugins` CLI entrypoint (`agb`, `agent-bridge`) sets nothing, so
# the dispatch below runs normally. Same pattern used by other root
# scripts to make smoke harnesses portable. (#1201 + #1202 smoke.)
if [[ "${BRIDGE_PLUGINS_LIB_ONLY:-0}" != "1" ]]; then
  case "${1:-}" in
    "")
      usage
      exit 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    help)
      shift
      bridge_plugins_cmd_help "$@"
      ;;
    seed)
      shift
      bridge_plugins_cmd_seed "$@"
      ;;
    add-marketplace)
      shift
      bridge_plugins_cmd_add_marketplace "$@"
      ;;
    show)
      shift
      bridge_plugins_cmd_show "$@"
      ;;
    list)
      shift
      bridge_plugins_cmd_list "$@"
      ;;
    marketplaces)
      shift
      bridge_plugins_cmd_marketplaces "$@"
      ;;
    *)
      bridge_warn "지원하지 않는 plugins 명령입니다: $1"
      usage
      exit 2
      ;;
  esac
fi
