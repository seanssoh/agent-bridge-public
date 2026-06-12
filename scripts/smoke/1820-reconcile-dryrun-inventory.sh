#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-reconcile-dryrun-inventory.sh — Issue #1820.
#
# Verdict gate (minimum, before dispatch): "A dry-run inventory smoke that seeds
# the live failure class: v2 home/workdir present, v1 memory fresher for many
# agents, and at least one divergent v1+v2 memory pair. Dry-run must write
# nothing and must classify every candidate."
#
# Drives the GATED wrapper (lib/bridge-layout-v2-reconcile.sh) end-to-end in
# dry-run mode, proving the fencing layer + data-root resolution from the marker
# AND the no-write inventory contract.

set -uo pipefail
SMOKE_NAME="1820-reconcile-dryrun-inventory"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
fi

smoke_setup_bridge_home "$SMOKE_NAME"

BH="$BRIDGE_HOME"; DR="$BRIDGE_DATA_ROOT"

# Seed 13 agents with v2 home present + v1 memory fresher (the live failure
# class: v1 MEMORY has extra appended lines a nightly cron wrote), and one
# divergent pair.
for i in $(seq 1 13); do
  a="agent$i"
  mkdir -p "$BH/agents/$a" "$DR/agents/$a/home"
  printf 'base\n' >"$DR/agents/$a/home/MEMORY.md"
  # v1 is a clean superset (fresher) for agents 1..12, divergent for agent13.
  if [[ "$i" -eq 13 ]]; then
    printf 'base\nv1-divergent\n' >"$BH/agents/$a/MEMORY.md"
    printf 'base\nv2-divergent\n' >"$DR/agents/$a/home/MEMORY.md"
  else
    printf 'base\nfresh-cron-line\n' >"$BH/agents/$a/MEMORY.md"
  fi
done

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  printf 'source %q >/dev/null 2>&1\n' "$REPO_ROOT/bridge-lib.sh"
  printf 'source %q >/dev/null 2>&1\n' "$REPO_ROOT/lib/bridge-lock.sh"
  printf 'source %q >/dev/null 2>&1\n' "$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh"
  printf '%s\n' 'bridge_layout_v2_reconcile_run --mode dry-run'
} >"$DRIVER"
chmod +x "$DRIVER"

OUT="$("$BRIDGE_BASH" "$DRIVER" 2>"$SMOKE_TMP_ROOT/err.log")"
RC=$?
[[ $RC -eq 0 ]] || { cat "$SMOKE_TMP_ROOT/err.log" >&2; smoke_fail "wrapper dry-run returned $RC"; }
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT" || { printf '%s\n' "$OUT" >&2; smoke_fail "dry-run did not emit valid JSON"; }

# Every candidate classified: 12 superset preserves + 1 divergent conflict.
python3 -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["mode"]=="dry-run", d["mode"]
preserved=[p for p in d["preserved"] if p["direction"]=="prefix_superset_v1"]
assert len(preserved)==12, f"expected 12 fresher-v1 supersets, got {len(preserved)}"
assert len(d["conflicted"])==1, f"expected 1 divergent conflict, got {len(d['"'"'conflicted'"'"'])}"
assert len(d["agents"])==13, f"expected 13 agents inventoried, got {len(d['"'"'agents'"'"'])}"
' "$OUT" || smoke_fail "dry-run classification wrong"
smoke_log "classification PASS: 12 fresher-v1 supersets + 1 divergent conflict, 13 agents inventoried"

# Dry-run must write NOTHING: no mutation to v2, no archive, no backup, no marker.
for i in $(seq 1 12); do
  v2m="$DR/agents/agent$i/home/MEMORY.md"
  [[ "$(cat "$v2m")" == "base" ]] || smoke_fail "dry-run MUTATED v2 ($v2m)"
done
grep -q 'v2-divergent' "$DR/agents/agent13/home/MEMORY.md" || smoke_fail "dry-run mutated divergent v2"
[[ -z "$(find "$DR" -name '*.CONFLICT.md' 2>/dev/null | head -1)" ]] || smoke_fail "dry-run wrote a conflict archive"
[[ ! -d "$BRIDGE_STATE_DIR/migration/layout-v2-reconcile/backups" ]] || smoke_fail "dry-run wrote a backup"
[[ ! -f "$BRIDGE_STATE_DIR/migration/layout-v2-reconcile/last-apply.json" ]] || smoke_fail "dry-run wrote the apply marker"
smoke_log "no-write PASS: dry-run mutated nothing (v2/archive/backup/marker all clean)"

smoke_log "all dry-run inventory tests PASS (#1820)"
