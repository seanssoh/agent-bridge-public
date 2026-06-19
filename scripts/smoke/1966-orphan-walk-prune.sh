#!/usr/bin/env bash
# scripts/smoke/1966-orphan-walk-prune.sh — Issue #1966 orphan keep-set walk.
#
# The orphan-dir keep-set walk (bridge_orphan_classifier.py's
# _enumerate_symlink_targets_under_root) was rewritten to PRUNE heavy
# non-symlink content trees (node_modules, .git, .claude/{projects,cache})
# during the walk and to read symlink-ness from a cached os.scandir DirEntry
# instead of a per-entry os.path.islink. The invariant the prune must hold is
# ORPHAN-CLASSIFICATION-PRESERVING for every BRIDGE keep (orphan count + every
# bridge/registered/infra child's verdict identical pre/post, the ONLY permitted
# change being the intended one-directional referenced-symlink-target -> orphan
# flip), NOT "keep-set RESULT byte-identical": on a real install the keep-set is
# NOT byte-identical because npm `.bin` shims (and any non-bridge symlink) buried
# in node_modules under a REGISTERED home are dropped. The same-home `.bin` drop
# changes no verdict (the registered child short-circuits to KIND_REGISTERED
# before the keep-set is consulted); a non-bridge symlink in a pruned tree
# pointing at an UNREGISTERED SIBLING flips it kept -> orphan, which is
# intended/safe (one-directional, never hides a real orphan).
#
# This smoke drives the non-vacuous correctness teeth in a sibling Python
# helper (1966-orphan-walk-prune-helper.py): it builds a fixture home_root with
# a REGISTERED agent home holding (a) an npm-`.bin`-style symlink and (b) a
# non-bridge symlink pointing at an UNREGISTERED SIBLING, both inside pruned
# node_modules (realpath under the home root) — so the keep-set genuinely DIFFERS
# pre/post — plus shallow bridge keep-links, heavy prunable trees, a scoped-prune
# anchoring decoy, and a genuine UNREGISTERED orphan. It proves the keep-set
# differs, then asserts the CLASSIFICATION result (per-child verdict + orphan
# count from classify_agent_home_root / count_orphan_agent_dirs) preserves every
# bridge keep with only the intended sibling flip, and proves the prune is real
# by instrumenting os.scandir.
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

smoke_run "bridge keeps classification-preserved; only intended sibling flip; prune real (keep-set differs)" \
  "$PY_BIN" "$HELPER" "$SMOKE_TMP_ROOT"

smoke_log "PASS"
