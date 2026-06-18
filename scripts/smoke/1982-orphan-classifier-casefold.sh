#!/usr/bin/env bash
# scripts/smoke/1982-orphan-classifier-casefold.sh — Issue #1982 smoke.
#
# The orphan-agent-dir classifier's registered fast-path
# (`bridge_orphan_classifier.py:_classify_child`, `if name in known:`) is a
# case-SENSITIVE set membership. On a case-INSENSITIVE volume (macOS APFS) an
# on-disk `agents/FOO-BAR` for a registered id `foo-bar` misses the fast-path,
# and the `os.path.samefile` fallback cannot rescue it when the agent's home
# was migrated to a PARALLEL tree (`data/agents/<id>/home`, a different inode)
# — so the dir is mis-classified `orphan-agent-dir` (the only quarantine-
# eligible kind), even though case-insensitively its name IS a registered
# agent. The fix shares the inode-aware, case-folding, fail-safe-toward-KEEP
# approach of the interactive retire guard (`bridge-agent.sh:6477`, #598
# Track 2) — though against a different base path (see the classifier
# docstring); cross-surface alignment with retire is a follow-up.
#
# This smoke drives the SSOT classifier (classify_agent_home_root) DIRECTLY so
# it covers the decision the GC, the doctor, and the status counter all share.
#
# Tests:
#   T1. (case-insensitive fs only) parallel-tree-migration case-variant:
#       registered `foo-bar` at data/agents/foo-bar/home, on-disk
#       `agents/FOO-BAR` → classified REGISTERED (NOT orphan). #1982 fix.
#   T2. a genuinely-unregistered dir → STILL `orphan-agent-dir` (teeth intact).
#   T3. a lowercase registered dir → STILL registered (no regression).
#   T4. case-SENSITIVE correctness: a dir whose name case-folds to a registered
#       id but is a genuinely DIFFERENT dir (no colliding sibling) → NOT
#       collapsed (classified orphan). Validated via the same case-fold seam so
#       it is portable to a case-sensitive Linux CI fs.
#
# Mutation non-vacuity: revert the fix (`name in known` only) and T1 flips to
# `orphan-agent-dir` (confirmed manually during authoring; the T1 assertion is
# the teeth).
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never touches the
# operator's live runtime.

set -euo pipefail

SMOKE_NAME="1982-orphan-classifier-casefold"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1982-orphan-classifier-casefold"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

CLASSIFIER="$REPO_ROOT/bridge_orphan_classifier.py"
smoke_assert_file_exists "$CLASSIFIER" "classifier module present"

HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT"
DATA_AGENTS="$SMOKE_TMP_ROOT/data/agents"

reset_tree() {
  rm -rf "$HOME_ROOT" "$DATA_AGENTS"
  mkdir -p "$HOME_ROOT" "$DATA_AGENTS"
}

# classify_kind <registry-json-file> <child-basename> -> the classifier's
# KIND for that child (or `__MISSING__` if the child was not enumerated).
# Imports the SSOT module and runs classify_agent_home_root, so this exercises
# the exact decision the GC / doctor / status counter share.
classify_kind() {
  local registry="$1"
  local target="$2"
  "$PY_BIN" - "$REPO_ROOT" "$registry" "$HOME_ROOT" "$target" <<'PY'
import json, sys
repo_root, registry_file, home_root, target = sys.argv[1:5]
sys.path.insert(0, repo_root)
from pathlib import Path
import bridge_orphan_classifier as C
with open(registry_file, encoding="utf-8") as fh:
    registry = json.load(fh)
rows = C.classify_agent_home_root(registry, Path(home_root))
by = {r["name"]: r["kind"] for r in rows}
print(by.get(target, "__MISSING__"))
PY
}

# write_registry <out> <id>=<home> [...] — minimal `agent registry --json`.
write_registry() {
  local out="$1"; shift
  "$PY_BIN" - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
rows = []
for spec in sys.argv[2:]:
    agent_id, home = spec.split("=", 1)
    rows.append({"id": agent_id, "class": "dynamic", "home": home,
                 "workdir": home, "engine": "claude", "is_alive": True,
                 "source": "dynamic-active-env"})
open(out, "w", encoding="utf-8").write(json.dumps(rows))
PY
}

# Is the home root on a case-insensitive fs? (Does a lowercase spelling reach
# the same inode as an on-disk uppercase dir we just created?)
home_root_is_case_insensitive() {
  local probe_upper="$HOME_ROOT/.ci-probe-UPPER"
  local probe_lower="$HOME_ROOT/.ci-probe-upper"
  rm -rf "$probe_upper" "$probe_lower"
  mkdir -p "$probe_upper"
  local ci=1
  if [[ -d "$probe_lower" ]] && [[ "$probe_lower" -ef "$probe_upper" ]]; then
    ci=0
  fi
  rm -rf "$probe_upper" "$probe_lower"
  return "$ci"
}

# ---------------------------------------------------------------------------
# T1 — parallel-tree-migration case-variant → REGISTERED (case-insensitive fs).
# ---------------------------------------------------------------------------
t1_parallel_tree_case_variant_kept() {
  reset_tree
  if ! home_root_is_case_insensitive; then
    smoke_log "T1 skip: case-sensitive fs — the case-variant collision is not reproducible here (covered by T4)"
    return 0
  fi
  # Registered `foo-bar`, home migrated to the parallel data tree (a different
  # inode from anything under the home root).
  local data_home="$DATA_AGENTS/foo-bar/home"
  mkdir -p "$data_home"
  # On-disk leftover under the home root, UPPER-cased.
  mkdir -p "$HOME_ROOT/FOO-BAR"
  printf 'live\n' >"$HOME_ROOT/FOO-BAR/marker.txt"

  local registry="$SMOKE_TMP_ROOT/r.t1.json"
  write_registry "$registry" "foo-bar=$data_home"

  local kind
  kind="$(classify_kind "$registry" "FOO-BAR")"
  smoke_assert_eq "registered" "$kind" \
    "T1 a parallel-tree case-variant of a registered agent is classified registered (#1982)"
}

# ---------------------------------------------------------------------------
# T2 — a genuinely-unregistered dir is STILL an orphan (teeth intact).
# ---------------------------------------------------------------------------
t2_genuine_orphan_still_flagged() {
  reset_tree
  local data_home="$DATA_AGENTS/foo-bar/home"
  mkdir -p "$data_home"
  mkdir -p "$HOME_ROOT/stranger-zzz"
  local registry="$SMOKE_TMP_ROOT/r.t2.json"
  write_registry "$registry" "foo-bar=$data_home"

  local kind
  kind="$(classify_kind "$registry" "stranger-zzz")"
  smoke_assert_eq "orphan-agent-dir" "$kind" \
    "T2 a genuinely-unregistered dir is still classified orphan-agent-dir"
}

# ---------------------------------------------------------------------------
# T3 — a lowercase registered dir is STILL registered (no regression).
# ---------------------------------------------------------------------------
t3_lowercase_registered_no_regression() {
  reset_tree
  # `baz` whose home is the conventional $HOME_ROOT/baz.
  mkdir -p "$HOME_ROOT/baz"
  local registry="$SMOKE_TMP_ROOT/r.t3.json"
  write_registry "$registry" "baz=$HOME_ROOT/baz"

  local kind
  kind="$(classify_kind "$registry" "baz")"
  smoke_assert_eq "registered" "$kind" \
    "T3 a lowercase registered dir is still classified registered (exact fast-path)"
}

# ---------------------------------------------------------------------------
# T4 — case-SENSITIVE correctness: a case-folding name with NO colliding
#      sibling must NOT be collapsed. Portable to a case-sensitive Linux fs;
#      on a case-insensitive fs we simulate the distinct-dir shape directly via
#      the casefold_registered_agent seam so the assertion still runs.
# ---------------------------------------------------------------------------
t4_case_sensitive_not_collapsed() {
  reset_tree
  # Drive the seam directly: a candidate whose basename case-folds to a
  # registered id but whose `home_root/<id>` sibling resolves to a DIFFERENT
  # real dir → the samefile probe fails → None (no collapse). This is exactly
  # what happens on a case-sensitive fs where FOO-BAR and foo-bar are distinct.
  local out
  out="$("$PY_BIN" - "$REPO_ROOT" "$SMOKE_TMP_ROOT" <<'PY'
import sys
repo_root, tmp = sys.argv[1:3]
sys.path.insert(0, repo_root)
from pathlib import Path
import bridge_orphan_classifier as C

cand = Path(tmp) / "cand-FOO-BAR"
cand.mkdir(parents=True, exist_ok=True)
other = Path(tmp) / "sibling-other"
other.mkdir(parents=True, exist_ok=True)

class CSRoot:
    """home_root/<id> resolves to a genuinely DIFFERENT dir (case-sensitive)."""
    def __truediv__(self, agent_id):
        return other

verdict = C.casefold_registered_agent(cand, "FOO-BAR", CSRoot(), {"foo-bar"})
if verdict is not None:
    print(f"FAIL: distinct-inode sibling collapsed to {verdict!r}")
    raise SystemExit(1)

# And an ABSENT sibling (case-sensitive fs with no lowercase dir) → no-match.
class MissingRoot:
    def __truediv__(self, agent_id):
        return Path(tmp) / "does-not-exist"

verdict2 = C.casefold_registered_agent(cand, "FOO-BAR", MissingRoot(), {"foo-bar"})
if verdict2 is not None:
    print(f"FAIL: absent sibling collapsed to {verdict2!r}")
    raise SystemExit(1)

print("OK")
PY
)"
  smoke_assert_eq "OK" "$out" \
    "T4 case-sensitive shape: a case-folding name with no colliding sibling is NOT collapsed"
}

# ---------------------------------------------------------------------------
# Drive cases.
# ---------------------------------------------------------------------------
smoke_run "T1 parallel-tree case-variant kept" t1_parallel_tree_case_variant_kept
smoke_run "T2 genuine orphan still flagged" t2_genuine_orphan_still_flagged
smoke_run "T3 lowercase registered no regression" t3_lowercase_registered_no_regression
smoke_run "T4 case-sensitive not collapsed" t4_case_sensitive_not_collapsed

smoke_log "all 1982-orphan-classifier-casefold cases passed"
