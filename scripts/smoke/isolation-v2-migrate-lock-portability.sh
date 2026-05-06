#!/usr/bin/env bash
# Smoke test for the isolation-v2 migrate lock primitive.
#
# Regression coverage for v0.8.0 → v0.8.1: macOS does not ship `flock(1)`
# by default, so the prior implementation broke every macOS upgrade at
# `bridge_isolation_v2_migrate_acquire_lock`. The replacement uses
# mkdir-based atomic lock + PID stale detection, which is portable across
# macOS / Linux / Bash 3.2+ baseline with no external deps.
#
# Asserts:
#   1. Lock acquire works with `flock` removed from PATH.
#   2. Live owner blocks a second acquire from a different process.
#   3. Stale lock (PID file points at dead process) is cleaned + acquirable.
#   4. Release after acquire removes the lock dir.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIDGE_BASH="${BRIDGE_BASH_BIN:-bash}"

# Use brew bash on macOS (system bash is 3.2 and lacks `declare -g`).
if [[ "$(uname)" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

TMPHOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-isolation-v2-lock.XXXXXX")"
trap 'rm -rf "$TMPHOME"' EXIT

# Build a sanitized PATH that has NO `flock` binary anywhere.
# Walk the existing PATH, filter out any directory containing flock.
STRIPPED_PATH=""
IFS=':' read -ra path_parts <<<"${PATH:-/usr/bin:/bin}"
for d in "${path_parts[@]}"; do
  [[ -n "$d" ]] || continue
  [[ -d "$d" ]] || continue
  if [[ ! -x "$d/flock" ]]; then
    STRIPPED_PATH="${STRIPPED_PATH}${STRIPPED_PATH:+:}$d"
  fi
done
export PATH="$STRIPPED_PATH"

# Sanity: confirm `flock` is genuinely unreachable.
if command -v flock >/dev/null 2>&1; then
  echo "[smoke:isolation-v2-migrate-lock-portability] FAIL: flock still reachable on stripped PATH" >&2
  exit 1
fi

run_in_repo() {
  cd "$REPO_ROOT"
  BRIDGE_HOME="$TMPHOME" \
  BRIDGE_STATE_DIR="$TMPHOME/state" \
  PATH="$STRIPPED_PATH" \
  "$BRIDGE_BASH" "$@"
}

mkdir -p "$TMPHOME/state"

# Test 1: acquire works without flock on PATH
out="$(run_in_repo -c '
source lib/bridge-core.sh
source lib/bridge-isolation-v2-migrate.sh
bridge_isolation_v2_migrate_acquire_lock
[[ -d "$BRIDGE_STATE_DIR/migration/migrate-isolation-v2.lock.d" ]] && echo lock-dir-present
bridge_isolation_v2_migrate_release_lock
[[ ! -d "$BRIDGE_STATE_DIR/migration/migrate-isolation-v2.lock.d" ]] && echo lock-dir-removed
' 2>&1)" || { echo "[smoke] T1 FAIL: $out"; exit 1; }
echo "$out" | grep -q "lock-dir-present" || { echo "[smoke] T1 FAIL: lock dir not created. out=$out"; exit 1; }
echo "$out" | grep -q "lock-dir-removed" || { echo "[smoke] T1 FAIL: lock dir not removed. out=$out"; exit 1; }
echo "[smoke] T1 PASS: acquire+release works without flock on PATH"

# Test 2: live owner blocks second acquire
out="$(run_in_repo -c '
source lib/bridge-core.sh
source lib/bridge-isolation-v2-migrate.sh
bridge_isolation_v2_migrate_acquire_lock
# Spawn a second process that tries to acquire — must fail with bridge_die.
'"$BRIDGE_BASH"' -c "source lib/bridge-core.sh; source lib/bridge-isolation-v2-migrate.sh; bridge_isolation_v2_migrate_acquire_lock" 2>&1 \
  | grep -q "another isolation-v2 migrate operation is in progress" \
  && echo blocked-by-live-owner
bridge_isolation_v2_migrate_release_lock
' 2>&1)" || true  # Inner bridge_die exits non-zero, outer captures
echo "$out" | grep -q "blocked-by-live-owner" || { echo "[smoke] T2 FAIL: live owner didn't block. out=$out"; exit 1; }
echo "[smoke] T2 PASS: live owner blocks second acquire"

# Test 3: stale lock (dead PID) is cleaned + reacquirable
LOCK_DIR="$TMPHOME/state/migration/migrate-isolation-v2.lock.d"
mkdir -p "$LOCK_DIR"
echo "999999" > "$LOCK_DIR/owner.pid"
out="$(run_in_repo -c '
source lib/bridge-core.sh
source lib/bridge-isolation-v2-migrate.sh
bridge_isolation_v2_migrate_acquire_lock && echo stale-cleaned
bridge_isolation_v2_migrate_release_lock
' 2>&1)" || { echo "[smoke] T3 FAIL: $out"; exit 1; }
echo "$out" | grep -q "stale-cleaned" || { echo "[smoke] T3 FAIL: stale lock not cleaned. out=$out"; exit 1; }
echo "[smoke] T3 PASS: stale lock (dead PID) cleaned + reacquired"

echo "[smoke:isolation-v2-migrate-lock-portability] all 3 tests PASS"
