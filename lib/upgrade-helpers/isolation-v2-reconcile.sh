#!/usr/bin/env bash
# isolation-v2-reconcile.sh — invoke the Phase 2 install-tree reconciler
# on `upgrade --apply`. Invoked by bridge-upgrade.sh via
# `bridge_upgrade_with_target_env $TARGET_ROOT $BRIDGE_BASH_BIN $0 \
#   $SOURCE_ROOT $TARGET_ROOT`.
#
# Invocation contract:
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root being upgraded)
#
# Output: per-row pipe lines on stdout (see
#         `bridge_isolation_v2_apply_install_tree_matrix`).
# Exit code: 0 when every required row was canonical or successfully
#            mutated; non-zero when one or more required rows failed.
#            Optional rows (state-agent-leaf scaffolds for absent
#            agents, etc.) degrade but do not flip the code.
#
# Footgun #11 — no heredocs. The reconciler module is sourced via
# bridge-lib.sh's normal load path; the per-row output is consumed
# from the function call's captured stdout, not a heredoc into a
# subprocess.

set -uo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"
bridge_load_roster

# `--all-agents` walks the eligible isolated roster so every agent's
# state-leaf + credential-grant rows fire. When the roster has no
# isolated agents, the reconciler still runs the install-scope rows
# once (data-root, lib-dir, marker-path-*, etc.).
bridge_isolation_v2_apply_install_tree_matrix \
  --mode apply --reason upgrade --all-agents
