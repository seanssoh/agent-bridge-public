#!/usr/bin/env bash
# scripts/smoke/1966-orphan-walk-prune.sh — Issue #1966 orphan keep-set walk.
#
# The orphan-dir keep-set walk (bridge_orphan_classifier.py's
# _enumerate_symlink_targets_under_root) was rewritten to PRUNE heavy
# non-symlink content trees (node_modules, .git, .claude/{projects,cache})
# during the walk and to read symlink-ness from a cached os.scandir DirEntry
# instead of a per-entry os.path.islink. The prune is a SPEED change only —
# the keep-set RESULT (referenced_symlink_target_realpaths) MUST be
# byte-identical pre/post, so the orphan-agent-dir COUNT cannot change.
#
# This smoke drives the non-vacuous correctness teeth in a sibling Python
# helper (1966-orphan-walk-prune-helper.py): it builds a fixture home_root
# with BOTH shallow keep-set symlinks (the only kind the bridge ever creates
# whose target resolves under the home root) AND heavy prunable trees with no
# keep-set symlink, then asserts the patched function returns the IDENTICAL
# set as an inline reimplementation of the pre-fix unpruned algorithm, and
# proves the prune is real by instrumenting os.scandir.
#
# Pure filesystem fixture under a temp dir — never touches the operator's live
# runtime. No bridge CLI / daemon dependency.

set -euo pipefail

SMOKE_NAME="1966-orphan-walk-prune"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "1966-orphan-walk-prune"

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

HELPER="$SCRIPT_DIR/1966-orphan-walk-prune-helper.py"
smoke_assert_file_exists "$HELPER" "1966 keep-set helper present"

smoke_run "keep-set byte-identical pre/post the prune (+ prune is real)" \
  "$PY_BIN" "$HELPER" "$SMOKE_TMP_ROOT"

smoke_log "PASS"
