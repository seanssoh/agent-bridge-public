#!/usr/bin/env bash
# isolation-v2-migrate.sh — apply the v0.8.0 T3 isolation-v2 migration as
# part of an upgrade run. Invoked by bridge-upgrade.sh via
# `bridge_upgrade_with_target_env $TARGET_ROOT $BRIDGE_BASH_BIN $0 $SOURCE_ROOT $TARGET_ROOT`.
#
# Invocation contract:
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root being upgraded)
#
# Output: a single JSON document on stdout describing the migration outcome
#         (see `bridge_isolation_v2_migrate_apply_for_upgrade --json` for the
#         schema).
#
# Footgun #11 third variant (task #4538): this body used to live as a
# `bridge_upgrade_with_target_env … bash -s -- … <<'EOF' … EOF` heredoc-stdin
# inline in bridge-upgrade.sh. Bash 5.3.9 wedges the parent in
# `heredoc_write -> write()` when the bash -s subprocess sources bridge-lib.sh
# + lib/bridge-isolation-v2-migrate.sh before the heredoc-write completes.
# Moving the body to a regular file removes the heredoc-stdin path entirely.

set -euo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"
bridge_load_roster
# shellcheck source=lib/bridge-isolation-v2-migrate.sh
source "$source_root/lib/bridge-isolation-v2-migrate.sh"

# #1971: on macOS the v2 groups are inert (ENFORCE is Linux-only), and
# the create path is now Linux-gated. Sweep any inert ab-* groups a
# pre-#1971 install left in "Users & Groups" before the migrate-apply
# emits its terminal JSON line. The helper is a no-op on non-Darwin and
# never fails the caller, so it cannot affect the upgrade outcome; its
# diagnostics go to stderr and never contaminate the JSON on stdout.
bridge_isolation_v2_darwin_cleanup_inert_groups || true

bridge_isolation_v2_migrate_apply_for_upgrade --target-root "$target_root" --json
