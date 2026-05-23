#!/usr/bin/env bash
# isolation-v2-workdir-backfill.sh — back-fill canonical identity
# markers from the tracked profile tree into the v2 runtime workspace
# for legacy / marker-only-migrated agents (issue #1113). Invoked by
# bridge-upgrade.sh via `bridge_upgrade_with_target_env $TARGET_ROOT
# $BRIDGE_BASH_BIN $0 $SOURCE_ROOT $TARGET_ROOT`.
#
# Invocation contract:
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root being upgraded)
#
# Output: a single JSON document on stdout summarizing the back-fill
#         (see `bridge_isolation_v2_backfill_workdir_identity --json`).
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock class): this body uses
# only command invocations + argv. No heredocs anywhere. The library
# function itself also avoids heredocs so the entire chain is heredoc-
# free. Sibling helper isolation-v2-migrate.sh documents the parent
# rationale for the lib/upgrade-helpers/ split.

set -euo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"
bridge_load_roster
# shellcheck source=lib/bridge-isolation-v2-workdir-backfill.sh
source "$source_root/lib/bridge-isolation-v2-workdir-backfill.sh"
bridge_isolation_v2_backfill_workdir_identity \
  --target-root "$target_root" --json
