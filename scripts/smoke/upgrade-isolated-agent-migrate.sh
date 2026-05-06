#!/usr/bin/env bash
# Smoke test for the v0.8.2 upgrade-time per-agent migration fix.
#
# Regression coverage for issue #652. v0.8.0 + v0.8.1 `agent-bridge upgrade
# --apply` aborted with PermissionError on Linux hosts that had at least one
# per-UID isolated agent — `bridge-upgrade.py:migrate_agent_home` walked the
# template tree, hit `agents/_template/memory/.gitkeep`, and called
# `target.exists()` against the 0700-mode owner-only `memory/` subtree of
# the isolated agent. The list-comprehension at `cmd_migrate_agents` then
# propagated the exception, blocking every other agent's migration.
#
# Two-layer fix in `bridge-upgrade.py`:
#   1. `migrate_agent_home` skips the `memory/` subtree of the template
#      (per-agent memory wiki is agent-owned data, created on first launch).
#   2. `cmd_migrate_agents` wraps each `migrate_agent_home` call in a
#      try/except for `PermissionError` and reports a structured
#      `skipped_isolated` entry so a single denied agent never aborts the
#      multi-agent loop.
#
# Asserts:
#   T1 — `migrate-agents --dry-run` over a normal agent home returns rc=0
#        and the JSON omits `memory/` from `created_dirs` (template-skip).
#   T2 — `migrate-agents --dry-run` over a 0000-mode agent home (controller
#        cannot stat into) returns rc=0 with `skipped_isolated_count >= 1`
#        and `skipped_isolated[*].agent == <locked-agent-name>`.
#   T3 — Mixed run (one normal + one locked) keeps the normal agent's
#        migration intact (`migrated_count == 1`) AND records the locked
#        one (`skipped_isolated_count == 1`). No abort.
#
# Notes:
#   - Linux + sudo gives a real per-UID setup; this smoke uses chmod-only
#     to force PermissionError, which is portable across macOS + Linux
#     without root, at the cost of not exercising the cross-UID stat path.
#     The import path under test is identical (Path.exists() raises
#     PermissionError in both cases), so the controller-side defensive
#     layer is covered by chmod-only here.
#   - `chmod 0000` on the agent dir is what forces the PermissionError.
#     We restore mode in the trap so cleanup works even on test failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPHOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-issue-652-smoke.XXXXXX")"

cleanup() {
  # Restore mode on any locked agent so rm -rf can succeed.
  if [[ -d "$TMPHOME/agents" ]]; then
    chmod -R u+rwX "$TMPHOME/agents" 2>/dev/null || true
  fi
  rm -rf "$TMPHOME"
}
trap cleanup EXIT

run_migrate() {
  local target_root="$1"
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" \
    --target-root "$target_root" \
    --dry-run
}

json_field() {
  local key="$1"
  python3 -c "
import json, sys
payload = json.loads(sys.stdin.read())
val = payload.get('$key')
if isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val if val is not None else '')
"
}

# ---------- T1: normal agent home, memory/ skipped from template walk ----------
T1_HOME="$TMPHOME/t1"
mkdir -p "$T1_HOME/agents/normal-agent/.claude"
echo "stub" > "$T1_HOME/agents/normal-agent/CLAUDE.md"
echo "stub" > "$T1_HOME/agents/normal-agent/MEMORY.md"

T1_OUT="$(run_migrate "$T1_HOME" 2>&1)" || {
  echo "[smoke:upgrade-isolated-agent-migrate] T1 FAIL: rc!=0"
  echo "$T1_OUT"
  exit 1
}

# created_dirs must NOT contain "memory" or any "memory/..." subdir.
if printf '%s' "$T1_OUT" | json_field created_dirs | grep -E '"memory(/|")' >/dev/null; then
  echo "[smoke:upgrade-isolated-agent-migrate] T1 FAIL: memory/ enumerated despite skip"
  printf '%s\n' "$T1_OUT"
  exit 1
fi
T1_AGENT_COUNT="$(printf '%s' "$T1_OUT" | json_field agent_count)"
T1_SKIPPED="$(printf '%s' "$T1_OUT" | json_field skipped_isolated_count)"
if [[ "$T1_AGENT_COUNT" != "1" ]] || [[ "$T1_SKIPPED" != "0" ]]; then
  echo "[smoke:upgrade-isolated-agent-migrate] T1 FAIL: expected agent_count=1 skipped_isolated_count=0, got agent_count=$T1_AGENT_COUNT skipped_isolated_count=$T1_SKIPPED"
  exit 1
fi
echo "[smoke] T1 PASS: normal agent migrated, memory/ skipped from template walk"

# ---------- T2: locked agent (0000) → PermissionError caught ----------
T2_HOME="$TMPHOME/t2"
mkdir -p "$T2_HOME/agents/locked-agent/.claude"
echo "stub" > "$T2_HOME/agents/locked-agent/CLAUDE.md"
chmod 0000 "$T2_HOME/agents/locked-agent"

T2_OUT="$(run_migrate "$T2_HOME" 2>&1)" || {
  chmod 0700 "$T2_HOME/agents/locked-agent"
  echo "[smoke:upgrade-isolated-agent-migrate] T2 FAIL: rc!=0 (PermissionError not caught)"
  echo "$T2_OUT"
  exit 1
}
chmod 0700 "$T2_HOME/agents/locked-agent"

T2_SKIPPED="$(printf '%s' "$T2_OUT" | json_field skipped_isolated_count)"
T2_AGENTS_DETAIL="$(printf '%s' "$T2_OUT" | json_field skipped_isolated)"
if [[ "$T2_SKIPPED" != "1" ]]; then
  echo "[smoke:upgrade-isolated-agent-migrate] T2 FAIL: expected skipped_isolated_count=1, got $T2_SKIPPED"
  printf '%s\n' "$T2_OUT"
  exit 1
fi
if ! printf '%s' "$T2_AGENTS_DETAIL" | grep -q '"locked-agent"'; then
  echo "[smoke:upgrade-isolated-agent-migrate] T2 FAIL: skipped_isolated entry missing locked-agent"
  printf '%s\n' "$T2_AGENTS_DETAIL"
  exit 1
fi
echo "[smoke] T2 PASS: locked agent reported as skipped_isolated, no abort"

# ---------- T3: mixed run — normal migrated + locked skipped ----------
T3_HOME="$TMPHOME/t3"
mkdir -p "$T3_HOME/agents/normal-agent/.claude"
echo "stub" > "$T3_HOME/agents/normal-agent/CLAUDE.md"
echo "stub" > "$T3_HOME/agents/normal-agent/MEMORY.md"
mkdir -p "$T3_HOME/agents/locked-agent/.claude"
echo "stub" > "$T3_HOME/agents/locked-agent/CLAUDE.md"
chmod 0000 "$T3_HOME/agents/locked-agent"

T3_OUT="$(run_migrate "$T3_HOME" 2>&1)" || {
  chmod 0700 "$T3_HOME/agents/locked-agent"
  echo "[smoke:upgrade-isolated-agent-migrate] T3 FAIL: rc!=0"
  echo "$T3_OUT"
  exit 1
}
chmod 0700 "$T3_HOME/agents/locked-agent"

T3_MIGRATED="$(printf '%s' "$T3_OUT" | json_field migrated_count)"
T3_SKIPPED="$(printf '%s' "$T3_OUT" | json_field skipped_isolated_count)"
T3_TOTAL="$(printf '%s' "$T3_OUT" | json_field agent_count)"
if [[ "$T3_MIGRATED" != "1" ]] || [[ "$T3_SKIPPED" != "1" ]] || [[ "$T3_TOTAL" != "2" ]]; then
  echo "[smoke:upgrade-isolated-agent-migrate] T3 FAIL: expected migrated=1 skipped=1 total=2, got migrated=$T3_MIGRATED skipped=$T3_SKIPPED total=$T3_TOTAL"
  printf '%s\n' "$T3_OUT"
  exit 1
fi
echo "[smoke] T3 PASS: mixed run — normal migrated AND locked skipped, no abort"

echo "[smoke:upgrade-isolated-agent-migrate] all 3 tests PASS"
