#!/usr/bin/env bash
# bundled-plugins-bun-install.sh — install node_modules for every
# bundled plugin that has a package.json. Standalone helper invoked
# file-as-argv per footgun #11 (no heredoc-stdin to subprocess).
#
# L1-J (beta20, 2026-05-25 patch L1-extended): bundled plugins like
# `teams`, `ms365`, and `cosmax-ep-approval` ship with package.json but
# no node_modules in source — Claude Code's plugin spawn path runs the
# plugin's MCP under the plugin tree, which `require()`s npm
# dependencies that are not present. Symptom: "Cannot find module
# '@modelcontextprotocol/sdk/...'" on first iso-UID MCP spawn.
#
# Fix path: this helper enumerates `$SOURCE_ROOT/plugins/*` and runs
# `bun install --frozen-lockfile` (when bun.lock present) or
# `bun install` in every plugin dir that has a `package.json` but no
# `node_modules`. The helper is idempotent — re-running on an already-
# installed plugin is a fast no-op (skip when node_modules exists and
# is the same age or newer than package.json + bun.lock).
#
# Invocation contract (mirrors bun-traverse-chmod.sh):
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root — informational; the
#        helper walks source_root/plugins/ which the upgrade has
#        already promoted into target_root by this point in the
#        upgrade flow)
#
# Exit code: 0 when every plugin's node_modules is present (after the
#            install pass) OR no plugin needed it; non-zero when at
#            least one plugin install failed. bridge-upgrade.sh treats
#            non-zero as a partial-failure warning, not a fatal abort.

set -uo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"

# L1-K (beta20, 2026-05-25): Node.js version detection. Several bundled
# and external plugins (cosmax-ep-approval is the canonical case in
# patch's report) use Node 14+ syntax (`?.`, `??`, top-level await
# under .mjs). Ubuntu 22.04 ships `node` at 12.22.9 by default. Detect
# the version and emit a loud warning (NOT a fatal error) so the
# operator sees the actionable diagnostic in the upgrade log.
#
# Option B (operator's preferred path 2026-05-25): warn loudly,
# document the fix (`nvm install --lts` / distro upgrade), do NOT
# silently symlink /usr/local/bin/node — that would mutate system
# PATH ownership across upgrades and create a hidden state surface.
_node_version_check() {
  local node_bin=""
  if ! node_bin="$(command -v node 2>/dev/null)" || [[ -z "$node_bin" ]]; then
    bridge_info "[bundled-plugins][node-check] node not on PATH — bundled MCPs that require Node.js will fail at spawn. Install Node 18 LTS via 'nvm install --lts' or your distro package manager."
    return 0
  fi
  local raw_version=""
  raw_version="$("$node_bin" --version 2>/dev/null || true)"
  # Format: "v12.22.9" or "v18.19.0".
  if [[ -z "$raw_version" ]]; then
    bridge_info "[bundled-plugins][node-check] node at $node_bin returned no --version output — cannot validate"
    return 0
  fi
  local major=""
  major="$(printf '%s\n' "$raw_version" | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ -z "$major" || ! "$major" =~ ^[0-9]+$ ]]; then
    bridge_info "[bundled-plugins][node-check] could not parse node version from '$raw_version'"
    return 0
  fi
  if (( major < 14 )); then
    bridge_warn "[bundled-plugins][node-check] node at $node_bin is $raw_version (< 14) — plugins using optional chaining (?.), nullish coalescing (??), or top-level await (e.g. cosmax-ep-approval's ep-mcp-proxy.mjs) will fail with SyntaxError on first spawn. Install Node 18 LTS: 'nvm install --lts' (then re-open shell), or upgrade your distro. This warning is non-fatal — bundled-plugin install continues."
    return 0
  fi
  bridge_info "[bundled-plugins][node-check] node $raw_version OK (>= 14)"
  return 0
}

_node_version_check || true

# The upgrade flow has already promoted source/plugins → target/plugins
# (the install-tree reconciler is the one that normalizes ownership +
# mode). Run bun install on the TARGET side so the resulting
# node_modules lands in the live install tree, where
# bridge-dev-plugin-cache.py can mirror it into per-agent caches.
plugins_root="$target_root/plugins"
if [[ ! -d "$plugins_root" ]]; then
  # Fresh install with no plugins ever copied — nothing to do.
  exit 0
fi

# Resolve bun binary. If absent on this host, the bundled MCPs cannot
# start anyway; emit a single line and bail out cleanly so the upgrade
# does NOT abort (operator may install bun later via
# `agb setup teams`).
bun_bin=""
if command -v bridge_resolve_bun_executable >/dev/null 2>&1; then
  bun_bin="$(bridge_resolve_bun_executable 2>/dev/null || true)"
fi
if [[ -z "$bun_bin" ]]; then
  bun_bin="$(command -v bun 2>/dev/null || true)"
fi
if [[ -z "$bun_bin" ]]; then
  bridge_info "[bundled-plugins] bun runtime not found on PATH — skipping node_modules install for bundled plugins. Run 'agb setup teams <agent>' to install bun + provision deps."
  exit 0
fi

# Honor dry-run.
_dry_run="${DRY_RUN:-0}"
if [[ "$_dry_run" != "1" ]]; then
  _dry_run=0
fi

# Walk every immediate subdir of plugins_root. Skip metadata dirs
# (marketplaces/, cache/) and dotfiles.
overall_rc=0
shopt -s nullglob 2>/dev/null || true
for plugin_dir in "$plugins_root"/*/; do
  plugin_dir="${plugin_dir%/}"
  [[ -d "$plugin_dir" ]] || continue
  plugin_name="$(basename -- "$plugin_dir")"
  case "$plugin_name" in
    marketplaces|cache|.*) continue ;;
  esac

  pkg_json="$plugin_dir/package.json"
  if [[ ! -f "$pkg_json" ]]; then
    continue
  fi

  node_modules="$plugin_dir/node_modules"
  # Idempotence: skip when node_modules is present AND newer than
  # package.json (and bun.lock, if present). This matches the pattern
  # `bridge_install_teams_plugin_node_modules` uses for the teams
  # plugin — but applies it generically so 4+ bundled plugins can
  # coexist.
  bun_lock="$plugin_dir/bun.lock"
  if [[ -d "$node_modules" ]]; then
    # Compare mtimes: node_modules vs package.json + bun.lock. Use
    # `find -newer` since stat formats differ across GNU/BSD.
    needs_install=0
    if [[ "$pkg_json" -nt "$node_modules" ]]; then
      needs_install=1
    fi
    if [[ -f "$bun_lock" && "$bun_lock" -nt "$node_modules" ]]; then
      needs_install=1
    fi
    if (( needs_install == 0 )); then
      # Best-effort widen of group/other read on the existing tree so
      # iso UIDs can copy via bridge-dev-plugin-cache.py. Mirrors the
      # behavior of bridge_install_teams_plugin_node_modules's
      # idempotent path (chmod always runs).
      chmod -R go+rX "$node_modules" 2>/dev/null \
        || bridge_warn "[bundled-plugins] chmod go+rX $node_modules failed — iso UIDs may fail to copy via bridge-dev-plugin-cache (non-fatal)"
      bridge_info "[bundled-plugins] $plugin_name: node_modules up to date (skipped)"
      continue
    fi
    bridge_info "[bundled-plugins] $plugin_name: node_modules stale vs package.json/bun.lock — refreshing"
  fi

  if [[ "$_dry_run" == "1" ]]; then
    bridge_info "[bundled-plugins] [dry-run] would run: bun install in $plugin_dir"
    continue
  fi

  # Use --frozen-lockfile when bun.lock present (deterministic), plain
  # `bun install` otherwise. `--no-summary` keeps the upgrade log tidy.
  bridge_info "[bundled-plugins] $plugin_name: running bun install in $plugin_dir"
  install_rc=0
  if [[ -f "$bun_lock" ]]; then
    ( cd "$plugin_dir" && "$bun_bin" install --frozen-lockfile --no-summary >&2 ) || install_rc=$?
  else
    ( cd "$plugin_dir" && "$bun_bin" install --no-summary >&2 ) || install_rc=$?
  fi
  if (( install_rc != 0 )); then
    bridge_warn "[bundled-plugins] $plugin_name: bun install failed (rc=$install_rc) — MCP for this plugin will not start until deps resolve"
    overall_rc=1
    continue
  fi

  # Same chmod widen as the teams helper: bun install runs under the
  # controller umask (often 077 → 0700) which iso UIDs can't traverse.
  if ! chmod -R go+rX "$node_modules" 2>/dev/null; then
    bridge_warn "[bundled-plugins] $plugin_name: chmod -R go+rX failed on $node_modules — isolated agents may fail to copy via bridge-dev-plugin-cache"
  fi
  bridge_info "[bundled-plugins] $plugin_name: node_modules installed + widened"
done

exit "$overall_rc"
