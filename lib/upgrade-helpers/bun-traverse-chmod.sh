#!/usr/bin/env bash
# bun-traverse-chmod.sh — invoke the Bun runtime traverse helper on
# `upgrade --apply`. Invoked by bridge-upgrade.sh via
# `bridge_upgrade_with_target_env $TARGET_ROOT $BRIDGE_BASH_BIN $0 \
#   $SOURCE_ROOT $TARGET_ROOT`.
#
# L1 beta19 (codex r1 design 2026-05-25): in-place upgrade from beta18
# is the acceptance path. The operator typically did not re-run
# `agb setup teams` between betas, so the `$HOME/.bun` traverse-chmod
# that bridge_provision_teams_plugin_runtime does at setup-teams time
# never fired on this host. Running the same helper here closes the gap.
#
# Invocation contract:
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root being upgraded)
#
# Output: helper-emitted bridge_info / bridge_warn lines on stderr (via
#         bridge_warn).
# Exit code: 0 when chmod was no-op (non-Linux, opt-out, bun outside
#            $HOME/.bun) or succeeded; non-zero only when an attempted
#            chmod actually failed. bridge-upgrade.sh treats non-zero
#            as a partial-failure warning, not a fatal abort.
#
# Footgun #11 — no heredocs. The function is sourced via bridge-lib.sh's
# normal load path; arguments come in as positional argv.

set -uo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"

# Honor dry-run via env (bridge-upgrade.sh sets DRY_RUN). The 0/1
# argument here is the literal flag the helper expects.
_dry_run="${DRY_RUN:-0}"
if [[ "$_dry_run" != "1" ]]; then
  _dry_run=0
fi

bridge_ensure_bun_runtime_traversable_for_isolated "$_dry_run"
