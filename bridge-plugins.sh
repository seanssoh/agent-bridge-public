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
  printf '  %s seed [--marketplace-root <path>] [--channels <csv>] [--dry-run] [--no-iso-chmod]\n' "$prog"
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
  local no_iso_chmod=0
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
  bridge_plugins_seed_mirror_marketplace_root "$marketplace_root" "$_seed_mkt_name" "$plugins_cache" \
    || bridge_warn "[plugins seed] marketplace mirror under $plugins_cache/marketplaces/$_seed_mkt_name: non-fatal failure (continuing)"

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
  bridge_plugins_seed_propagate_iso_known_marketplaces "$marketplace_root" "$_seed_mkt_name" \
    || bridge_warn "[plugins seed] iso known_marketplaces.json propagation: non-fatal failure (continuing)"

  printf '[ok] seeded %s (installed_plugins.json present)\n' "$plugins_cache"
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
    local rc=0
    if ! bridge_linux_sudo_root python3 \
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
